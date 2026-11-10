import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/media_api.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A bot SENDING files (contract 2026-11-07-encrypted-media): encrypt +
/// upload with calltype_protocol MediaCipher, the `media` message the app
/// reads, and the round trip through the bot's own receive path.
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late CallTypeBot bot;
  final logs = <String>[];
  final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';

  setUp(() async {
    logs.clear();
    dir = await Directory.systemTemp.createTemp('calltype_bot_send_media');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.handles['CT-AAAA-0001'] = alice.id;
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    bot.mediaTools = BotMediaTools.disabled();
    await bot.onMessage((_) async {});
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> lastPayload() => alice.readPayload(
    bot.deviceId,
    (hub.calls('SendReliableDirectFanout').last[3]
        as Map<String, String>)[alice.id]!,
  );

  Uint8List bytes(int n, [int seed = 7]) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

  Future<File> write(String name, List<int> content) async =>
      File('${dir.path}/$name')..writeAsBytesSync(content);

  /// What the app does with a received media payload, via the bot's
  /// receive path: parse, download, decrypt, verify.
  Future<Uint8List> receive(Map<String, dynamic> payload) async {
    final client = ApiClient(baseUrl: api.url);
    final attachment = BotAttachment.fromMedia(
      payload['media'],
      client.downloadMedia,
    );
    expect(attachment, isNotNull, reason: 'media object must validate');
    return attachment!.readBytes(maxBytes: 50 << 20);
  }

  bool ffmpegRuns() {
    try {
      return Process.runSync(ffmpeg, ['-version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  test('a document goes through the media path and round-trips', () async {
    final content = bytes(300 * 1024);
    final file = await write('report.pdf', content);
    final sent = await bot.sendFile(
      to: 'CT-AAAA-0001',
      path: file.path,
      caption: 'Zprava za listopad',
    );
    final payload = await lastPayload();
    expect(payload['id'], sent.id);
    expect(payload['type'], 'text');
    expect(payload['to'], alice.id);
    expect(
      payload['body'],
      '📎 report.pdf (${formatMediaSize(content.length)}). '
      'Update Jay to download it.\nZprava za listopad',
    );
    final media = MediaInfo.tryParse(payload['media'])!;
    expect(media.kind, MediaKind.file);
    expect(media.name, 'report.pdf');
    expect(media.mime, 'application/pdf');
    expect(media.size, content.length);
    expect(media.caption, 'Zprava za listopad');
    expect(media.expiresAt, isNotNull);
    expect(await receive(payload), content);
    // The server only ever saw ciphertext of the declared length.
    final blob = api.media[media.id]!;
    expect(blob.length, content.length + 16);
    expect(String.fromCharCodes(blob).contains('Zprava'), isFalse);
  });

  test('multi-chunk upload streams every chunk and survives a 503', () async {
    final content = bytes(2 * mediaMinChunkSize + 12345, 3);
    final file = await write('big.bin', content);
    api.failChunkPuts = 1;
    final info = await uploadMediaFile(
      ApiClient(baseUrl: api.url),
      file,
      kind: MediaKind.file,
      name: 'big.bin',
      mime: 'application/octet-stream',
      chunkSize: mediaMinChunkSize,
      retryDelay: Duration.zero,
    );
    expect(
      api.requests.where((r) => r.startsWith('PUT /media/')).length,
      4, // 3 chunks + the retried one
    );
    final attachment = BotAttachment.fromMedia(
      info.toJson(),
      ApiClient(baseUrl: api.url).downloadMedia,
    )!;
    final out = await attachment.saveTo('${dir.path}/out.bin');
    expect(await out.readAsBytes(), content);
  });

  test('an empty file is one empty chunk and round-trips', () async {
    final file = await write('empty.txt', const []);
    await bot.sendFile(to: 'CT-AAAA-0001', path: file.path);
    final payload = await lastPayload();
    expect(MediaInfo.tryParse(payload['media'])!.size, 0);
    expect(await receive(payload), isEmpty);
  });

  test('a small image goes inline like the app\'s photos', () async {
    final content = bytes(2000);
    final file = await write('photo.png', content);
    await bot.sendFile(to: 'CT-AAAA-0001', path: file.path, caption: 'Graf');
    final payload = await lastPayload();
    expect(payload['type'], 'file');
    expect(payload.containsKey('media'), isFalse);
    final attachment = BotAttachment.fromInlineBody(payload['body'])!;
    expect(attachment.name, 'photo.png');
    expect(attachment.caption, 'Graf');
    expect(await attachment.readBytes(maxBytes: 1 << 20), content);
    expect(api.uploads, isEmpty);
  });

  test('inlineSmallImages false sends the image as media', () async {
    final file = await write('photo.jpg', bytes(2000));
    await bot.sendFile(
      to: 'CT-AAAA-0001',
      path: file.path,
      inlineSmallImages: false,
    );
    final payload = await lastPayload();
    expect(payload['type'], 'text');
    expect(MediaInfo.tryParse(payload['media'])!.kind, MediaKind.image);
    expect(payload['body'], startsWith('🖼 Photo ('));
  });

  test('a server refusal is BotMediaRefused and nothing is sent', () async {
    final file = await write('x.zip', bytes(1000));
    api.mediaCreateFailure = (413, 'media_too_large');
    await expectLater(
      bot.sendFile(to: 'CT-AAAA-0001', path: file.path),
      throwsA(
        isA<BotMediaRefused>()
            .having((e) => e.statusCode, 'status', 413)
            .having((e) => e.code, 'code', 'media_too_large'),
      ),
    );
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });

  test('a file over maxFileBytes fails before any upload request', () async {
    final file = await write('x.bin', bytes(5000));
    bot.maxFileBytes = 4000;
    await expectLater(
      bot.sendFile(to: 'CT-AAAA-0001', path: file.path),
      throwsA(isA<BotMediaTooLarge>()),
    );
    expect(api.requests.where((r) => r.contains('/media')), isEmpty);
  });

  test('a failed chunk withdraws the upload', () async {
    final file = await write('x.bin', bytes(5000));
    api.failChunkPuts = 3;
    await expectLater(
      bot.sendFile(to: 'CT-AAAA-0001', path: file.path),
      throwsA(anything),
    );
    expect(api.deletedMedia, hasLength(1));
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });

  test('a missing file is an ArgumentError', () async {
    await expectLater(
      bot.sendFile(to: 'CT-AAAA-0001', path: '${dir.path}/nope.txt'),
      throwsArgumentError,
    );
  });

  test('voice without ffmpeg: the MP3 goes as is, kind voice', () async {
    final file = await write('reply.mp3', bytes(4000));
    await bot.sendFile(
      to: 'CT-AAAA-0001',
      path: file.path,
      kind: MediaKind.voice,
      durationMs: 1500,
    );
    final payload = await lastPayload();
    final media = MediaInfo.tryParse(payload['media'])!;
    expect(media.kind, MediaKind.voice);
    expect(media.mime, 'audio/mpeg');
    expect(media.durationMs, 1500);
    expect(payload['body'], startsWith('🎤 Voice message (0:02).'));
  });

  test(
    'voice with ffmpeg: AAC m4a, audio/mp4, duration and waveform',
    () async {
      if (!ffmpegRuns()) {
        markTestSkipped('ffmpeg not available');
        return;
      }
      bot.mediaTools = BotMediaTools(ffmpeg: ffmpeg);
      final wav = '${dir.path}/tone.wav';
      final made = await Process.run(ffmpeg, [
        '-nostdin', '-loglevel', 'error', '-y', //
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1.5', wav,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      await bot.sendFile(to: 'CT-AAAA-0001', path: wav, kind: MediaKind.voice);
      final payload = await lastPayload();
      final media = MediaInfo.tryParse(payload['media'])!;
      expect(media.kind, MediaKind.voice);
      expect(media.mime, 'audio/mp4');
      expect(media.name, matches(RegExp(r'^voice-\d{8}-\d{6}\.m4a$')));
      expect(media.durationMs, inInclusiveRange(1400, 1700));
      expect(media.waveform, hasLength(64));
      expect(media.waveform!.reduce((a, b) => a > b ? a : b), greaterThan(150));
      final audio = await receive(payload);
      final out = File('${dir.path}/back.m4a')..writeAsBytesSync(audio);
      final probe = await Process.run(BotMediaTools(ffmpeg: ffmpeg).ffprobe, [
        '-v', 'error', '-show_entries', 'stream=codec_name,channels', //
        '-of', 'json', out.path,
      ]);
      final stream =
          ((jsonDecode('${probe.stdout}') as Map)['streams'] as List).single
              as Map;
      expect(stream['codec_name'], 'aac');
      expect(stream['channels'], 1);
    },
  );

  test(
    'image via media path gets a JPEG thumbnail <= 320 px with ffmpeg',
    () async {
      if (!ffmpegRuns()) {
        markTestSkipped('ffmpeg not available');
        return;
      }
      bot.mediaTools = BotMediaTools(ffmpeg: ffmpeg);
      final png = '${dir.path}/big.png';
      final made = await Process.run(ffmpeg, [
        '-nostdin', '-loglevel', 'error', '-y', //
        '-f', 'lavfi', '-i', 'testsrc=size=1280x720:rate=1', '-frames:v', '1',
        png,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      await bot.sendFile(
        to: 'CT-AAAA-0001',
        path: png,
        inlineSmallImages: false,
      );
      final media = MediaInfo.tryParse((await lastPayload())['media'])!;
      expect(media.width, 1280);
      expect(media.height, 720);
      final thumb = media.thumbnail!;
      final dims = jpegDimensions(thumb)!;
      expect(dims.width, 320);
      expect(dims.height, 180);
      expect(thumb.length, lessThanOrEqualTo(mediaThumbnailMaxBytes));
    },
  );

  test('replyFile in a group quotes the message', () async {
    const groupId = '00000000-0000-4000-8000-0000000000c0';
    api.groups[groupId] = [alice.id, bot.deviceId];
    BotMessage? got;
    final file = await write('notes.txt', utf8.encode('hello'));
    await bot.onMessage((m) async {
      got = m;
      await m.replyFile(file.path, caption: 'tady');
    });
    hub.deliver(
      await alice.messageTo(
        bot.deviceId,
        api.botBundle,
        '@Hermes send it',
        groupId: groupId,
      ),
    );
    await until(() => hub.calls('SendReliableGroupFanout').isNotEmpty);
    final payload = await alice.readPayload(
      bot.deviceId,
      (hub.calls('SendReliableGroupFanout').last[3]
          as Map<String, String>)[alice.id]!,
    );
    expect(payload['groupId'], groupId);
    expect((payload['replyTo'] as Map)['id'], got!.id);
    final media = MediaInfo.tryParse(payload['media'])!;
    expect(media.name, 'notes.txt');
    expect(media.mime, 'text/plain');
    expect(utf8.decode(await receive(payload)), 'hello');
  });
}
