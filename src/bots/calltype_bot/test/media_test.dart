import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:test/test.dart';

import 'fixtures/make_media_fixture.dart' show fixturePlaintext;
import 'helpers.dart';

/// Received media (spec 2026-11-07-encrypted-media, section 3) and old
/// inline files: decode, download, decrypt, verify. Blobs are made with the
/// app's encoder (calltype_protocol MediaCipher + MediaInfo).
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late CallTypeBot bot;
  final logs = <String>[];

  setUp(() async {
    logs.clear();
    dir = await Directory.systemTemp.createTemp('calltype_bot_media_test');
    api = await FakeApi.start();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.handles['CT-AAAA-0001'] = alice.id;
    hub = FakeHub();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  /// Delivers one payload from alice exactly like the app's ChatController
  /// (`to` = the bot, millisecond `createdAt`) and waits for the ack.
  Future<void> deliver(
    String body, {
    Map<String, dynamic> extra = const {},
  }) async {
    final before = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await alice.messageTo(
        bot.deviceId,
        api.botBundle,
        body,
        to: bot.deviceId,
        extra: {
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          ...extra,
        },
      ),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
  }

  Future<Map<String, Object?>> upload(
    Uint8List plain, {
    MediaKind kind = MediaKind.voice,
    String name = 'voice.m4a',
    String mime = 'audio/mp4',
    int? durationMs = 10400,
    String? caption,
  }) => uploadMedia(
    api,
    plain,
    kind: kind,
    name: name,
    mime: mime,
    durationMs: durationMs,
    caption: caption,
  );

  Future<BotMessage> receiveMedia(
    Map<String, Object?> media, {
    String fallback =
        '🎤 Hlasová zpráva (0:10). Pro přehrání aktualizujte Jay.',
  }) async {
    final got = <BotMessage>[];
    await bot.onMessage((m) async => got.add(m));
    await deliver(fallback, extra: {'media': media});
    return got.single;
  }

  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) % 256));

  test('the committed app fixture decrypts (wire format pinned)', () async {
    final fixture =
        jsonDecode(File('test/fixtures/media_voice_v1.json').readAsStringSync())
            as Map<String, dynamic>;
    final media = fixture['media'] as Map<String, dynamic>;
    api.media[(media['id'] as String).toLowerCase()] = base64Decode(
      fixture['blob'] as String,
    );
    final m = await receiveMedia(
      media,
      fallback:
          '🎤 Hlasová zpráva (0:10). Pro přehrání aktualizujte Jay.\nkoupit mleko',
    );
    final a = m.attachment!;
    expect(a.kind, MediaKind.voice);
    expect(a.name, 'voice-20261107-101500.m4a');
    expect(a.mime, 'audio/mp4');
    expect(a.size, 3000);
    expect(a.duration, const Duration(milliseconds: 10400));
    expect(a.caption, 'koupit mleko');
    expect(a.expiresAt, DateTime.utc(2026, 11, 10, 9, 15, 2));
    expect(a.isInline, isFalse);
    // Text-only handlers keep seeing what an old client shows.
    expect(m.text, contains('Hlasová zpráva'));
    final file = await a.saveTo('${dir.path}/fixture.m4a');
    expect(await file.readAsBytes(), fixturePlaintext());
  });

  test('multi-chunk voice message downloads, decrypts and verifies', () async {
    final plain = bytes(mediaMinChunkSize * 2 + 12345);
    final m = await receiveMedia(await upload(plain, caption: 'hi'));
    expect(m.attachment!.caption, 'hi');
    final file = await m.attachment!.saveTo('${dir.path}/v.m4a');
    expect(await file.readAsBytes(), plain);
    expect(File('${dir.path}/v.m4a.part').existsSync(), isFalse);
    // The same bytes in memory.
    expect(await m.attachment!.readBytes(maxBytes: plain.length), plain);
  });

  test('an empty file is one empty final chunk', () async {
    final m = await receiveMedia(
      await upload(Uint8List(0), kind: MediaKind.file, name: 'empty.txt'),
    );
    final file = await m.attachment!.saveTo('${dir.path}/empty.txt');
    expect(await file.length(), 0);
  });

  test('a flipped bit is MediaTampered and leaves no file', () async {
    final plain = bytes(5000);
    final media = await upload(plain);
    final blob = api.media.values.single;
    blob[100] ^= 1;
    final m = await receiveMedia(media);
    await expectLater(
      m.attachment!.saveTo('${dir.path}/x.m4a'),
      throwsA(isA<MediaTampered>()),
    );
    expect(File('${dir.path}/x.m4a').existsSync(), isFalse);
    expect(File('${dir.path}/x.m4a.part').existsSync(), isFalse);
  });

  test('a truncated blob (last chunk dropped) is MediaTampered', () async {
    final plain = bytes(mediaMinChunkSize + 10);
    final media = await upload(plain);
    final id = api.media.keys.single;
    api.media[id] = api.media[id]!.sublist(0, mediaMinChunkSize + 16);
    final m = await receiveMedia(media);
    await expectLater(
      m.attachment!.saveTo('${dir.path}/x.m4a'),
      throwsA(isA<MediaTampered>()),
    );
    expect(File('${dir.path}/x.m4a.part').existsSync(), isFalse);
  });

  test('a wrong sha256 in the message is MediaHashMismatch', () async {
    final media = await upload(bytes(4000));
    media['sha256'] = base64Encode(List.filled(32, 7));
    final m = await receiveMedia(media);
    await expectLater(
      m.attachment!.saveTo('${dir.path}/x.m4a'),
      throwsA(isA<MediaHashMismatch>()),
    );
    expect(File('${dir.path}/x.m4a').existsSync(), isFalse);
  });

  test('expired media (410 / 404) is BotMediaExpired', () async {
    final media = await upload(bytes(10));
    api.mediaStatus[api.media.keys.single] = 410;
    final m = await receiveMedia(media);
    await expectLater(
      m.attachment!.saveTo('${dir.path}/x'),
      throwsA(isA<BotMediaExpired>()),
    );
    api.mediaStatus.clear();
    api.media.clear();
    await expectLater(
      m.attachment!.saveTo('${dir.path}/x'),
      throwsA(isA<BotMediaExpired>()),
    );
  });

  test('a size cap refuses before any request', () async {
    final m = await receiveMedia(await upload(bytes(2000)));
    final before = api.requests.where((r) => r.startsWith('GET /media')).length;
    await expectLater(
      m.attachment!.saveTo('${dir.path}/x', maxBytes: 1999),
      throwsA(isA<BotMediaTooLarge>()),
    );
    await expectLater(
      m.attachment!.readBytes(maxBytes: 10),
      throwsA(isA<BotMediaTooLarge>()),
    );
    expect(
      api.requests.where((r) => r.startsWith('GET /media')).length,
      before,
    );
  });

  test('an invalid media object leaves a plain text message', () async {
    final media = await upload(bytes(10));
    media['key'] = base64Encode([1, 2, 3]);
    final m = await receiveMedia(media, fallback: 'fallback text');
    expect(m.attachment, isNull);
    expect(m.text, 'fallback text');
  });

  test('image metadata: kind, mime, dimensions', () async {
    final media = await upload(
      bytes(100),
      kind: MediaKind.image,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      durationMs: null,
    );
    media['width'] = 640;
    media['height'] = 480;
    final m = await receiveMedia(media);
    expect(m.attachment!.kind, MediaKind.image);
    expect(m.attachment!.width, 640);
    expect(m.attachment!.duration, isNull);
  });

  group('inline file (old type: file)', () {
    String inlineBody(List<int> data, {Object? caption}) => jsonEncode({
      'name': 'note.png',
      'data': base64Encode(data),
      'caption': ?caption,
    });

    test('with receiveFiles: bytes, caption as text', () async {
      final got = <BotMessage>[];
      await bot.onMessage((m) async => got.add(m), receiveFiles: true);
      final data = bytes(1000);
      await deliver(
        inlineBody(data, caption: ' look '),
        extra: {'type': 'file'},
      );
      final a = got.single.attachment!;
      expect(a.isInline, isTrue);
      expect(a.kind, MediaKind.image);
      expect(a.mime, 'image/png');
      expect(a.size, 1000);
      expect(a.caption, 'look');
      expect(got.single.text, 'look');
      expect(await a.readBytes(maxBytes: 1000), data);
      final file = await a.saveTo('${dir.path}/note.png');
      expect(await file.readAsBytes(), data);
    });

    test('without a caption the text is empty', () async {
      final got = <BotMessage>[];
      await bot.onMessage((m) async => got.add(m), receiveFiles: true);
      await deliver(inlineBody([1, 2, 3]), extra: {'type': 'file'});
      expect(got.single.text, '');
      expect(got.single.attachment!.caption, isNull);
    });

    test('a malformed caption is dropped, the file stays', () async {
      final got = <BotMessage>[];
      await bot.onMessage((m) async => got.add(m), receiveFiles: true);
      await deliver(inlineBody([1], caption: 42), extra: {'type': 'file'});
      expect(got.single.attachment!.caption, isNull);
    });

    test('without receiveFiles it is acked and ignored (as before)', () async {
      final got = <BotMessage>[];
      await bot.onMessage((m) async => got.add(m));
      await deliver(inlineBody([1, 2, 3]), extra: {'type': 'file'});
      expect(got, isEmpty);
    });

    test('an invalid inline body is acked and dropped', () async {
      final got = <BotMessage>[];
      await bot.onMessage((m) async => got.add(m), receiveFiles: true);
      await deliver(
        jsonEncode({'name': '../x', 'data': 'AA=='}),
        extra: {'type': 'file'},
      );
      expect(got, isEmpty);
      expect(
        logs.where((l) => l.contains('invalid inline file')),
        hasLength(1),
      );
    });
  });

  test('a reaction in the exact app wire format reaches onReaction', () async {
    // chat_controller.react: type reaction, body = ReactionPayload JSON,
    // `to` = the bot (the 1:1 conversation id), createdAt in milliseconds,
    // groupId / groupName null.
    final reactions = <BotReaction>[];
    bot.onReaction((r) async => reactions.add(r));
    await bot.onMessage((m) async => m.reply('Deployed to beta.'));
    await deliver('hi');
    final sentId =
        (await alice.readPayload(
              bot.deviceId,
              (hub.calls('SendReliableDirectFanout').last[3]
                  as Map<String, String>)[alice.id]!,
            ))['id']
            as String;
    await deliver(
      ReactionPayload(targetId: sentId, emoji: '👍').encode(),
      extra: {
        'type': reactionType,
        'createdAt': DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
        ).toUtc().toIso8601String(),
      },
    );
    expect(reactions.single.emoji, '👍');
    expect(reactions.single.targetIsOwn, isTrue);
    expect(reactions.single.targetText, 'Deployed to beta.');
    expect(reactions.single.senderId, alice.id);
  });
}
