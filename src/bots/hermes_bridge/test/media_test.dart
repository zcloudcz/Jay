import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';

/// Received voice messages, images and files reach Hermes (README "Voice
/// messages, images and files"). Real crypto, fake hub, fake STT, fake
/// Hermes backend.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice; // owner
  late FakeUser peer; // a bot in the group
  late CallTypeBot bot;
  final prompts = <String>[];
  final imageTurns = <(String, List<HermesImage>)>[];
  final transcribed = <(List<int>, String)>[];
  final logs = <String>[];
  var sttAnswer = 'Ahoj, kup mléko.';

  Stream<HermesEvent> stream(String text, {required String conversationId}) {
    prompts.add(text);
    return Stream.value(HermesCompleted('answer ${prompts.length}'));
  }

  Stream<HermesEvent> multimodal(
    String text,
    List<HermesImage> images, {
    required String conversationId,
  }) {
    imageTurns.add((text, images));
    return Stream.value(const HermesCompleted('nice picture'));
  }

  Future<String> fakeStt(File audio, {required String mime}) async {
    transcribed.add((await audio.readAsBytes(), mime));
    return sttAnswer;
  }

  setUp(() async {
    prompts.clear();
    imageTurns.clear();
    transcribed.clear();
    logs.clear();
    sttAnswer = 'Ahoj, kup mléko.';
    dir = await Directory.systemTemp.createTemp('hermes_bridge_media');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    peer = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.handles['CT-AAAA-0001'] = alice.id;
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.keyBundles[peer.id] = await peer.keyBundle();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    api.groups[groupId] = [alice.id, peer.id, bot.deviceId];
    api.memberFields[alice.id] = {'role': 'admin'};
    api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0002'};
    api.groupDetails[groupId] = {
      'groupId': groupId,
      'botTalk': {'mode': 'all', 'maxBotTurns': 5},
    };
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await peer.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  String mediaDir() => '${dir.path}/media';

  MediaProcessor processor({
    Transcriber? stt,
    bool useStt = true,
    int maxFileBytes = 200 * 1000 * 1000,
    int sttMaxBytes = 25 * 1000 * 1000,
    bool imageInput = true,
  }) => MediaProcessor(
    settings: MediaSettings(
      dir: mediaDir(),
      maxFileBytes: maxFileBytes,
      sttMaxBytes: sttMaxBytes,
      imageInput: imageInput,
    ),
    transcribe: useStt ? (stt ?? fakeStt) : null,
    log: logs.add,
  );

  Future<HermesBridge> start({MediaProcessor? media, bool withImages = true}) =>
      runBridge(
        bot,
        allowedHandles: {'CT-AAAA-0001'},
        stream: stream,
        multimodal: withImages ? multimodal : null,
        progress: ProgressSettings.never,
        media: media,
        log: logs.add,
      );

  /// Delivers like the app (`to` = the bot) and waits for the ack.
  Future<void> deliver(
    FakeUser from,
    String body, {
    String? group,
    Map<String, dynamic> extra = const {},
  }) async {
    final before = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await from.messageTo(
        bot.deviceId,
        api.botBundle,
        body,
        groupId: group,
        to: group == null ? bot.deviceId : null,
        extra: extra,
      ),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
  }

  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 13 + 5) % 256));

  const voiceFallback =
      '🎤 Hlasová zpráva (0:10). Pro přehrání aktualizujte Jay.';

  test('voice message: transcript as the user turn, caption kept', () async {
    await start(media: processor());
    final audio = bytes(3000);
    final media = await uploadMedia(api, audio, caption: 'důležité');
    await deliver(alice, '$voiceFallback\ndůležité', extra: {'media': media});
    await until(() => prompts.isNotEmpty);
    expect(
      prompts.single,
      endsWith(
        '[from CT-AAAA-0001]: [hlasová zpráva 0:10, přepis]: Ahoj, kup mléko.'
        '\ndůležité',
      ),
    );
    expect(prompts.single, isNot(contains('aktualizujte')));
    // The STT got the decrypted audio with the sender's MIME type.
    expect(transcribed.single.$1, audio);
    expect(transcribed.single.$2, 'audio/mp4');
    // Saved under the media dir, which only the bridge user can read.
    final saved = Directory(mediaDir()).listSync(recursive: true);
    expect(saved.whereType<File>(), hasLength(1));
    final mode = (await Process.run('stat', ['-c', '%a', mediaDir()])).stdout;
    expect((mode as String).trim(), '700');
  });

  test('voice message without an STT key: a clear note', () async {
    await start(media: processor(useStt: false));
    await deliver(
      alice,
      voiceFallback,
      extra: {'media': await uploadMedia(api, bytes(100))},
    );
    await until(() => prompts.isNotEmpty);
    expect(
      prompts.single,
      contains(
        '[hlasová zpráva 0:10: přepis není k dispozici, bridge nemá '
        'nastavený ELEVENLABS_API_KEY; soubor: ${mediaDir()}/',
      ),
    );
    expect(transcribed, isEmpty);
  });

  test('voice message over 10 minutes is not transcribed', () async {
    await start(media: processor());
    await deliver(
      alice,
      voiceFallback,
      extra: {
        'media': await uploadMedia(api, bytes(100), durationMs: 11 * 60000),
      },
    );
    await until(() => prompts.isNotEmpty);
    expect(prompts.single, contains('[hlasová zpráva 11:00, 100 B: příliš'));
    expect(prompts.single, contains('limit 10 min / 25.0 MB'));
    expect(transcribed, isEmpty);
  });

  test('audio above the STT byte cap is not transcribed', () async {
    await start(media: processor(sttMaxBytes: 1000));
    await deliver(
      alice,
      'fallback',
      extra: {
        'media': await uploadMedia(
          api,
          bytes(2000),
          kind: MediaKind.audio,
          name: 'song.mp3',
          mime: 'audio/mpeg',
          durationMs: 30000,
        ),
      },
    );
    await until(() => prompts.isNotEmpty);
    expect(prompts.single, contains('[zvuková nahrávka song.mp3 0:30, 2.0 KB'));
    expect(prompts.single, contains('příliš dlouhá na přepis'));
    expect(transcribed, isEmpty);
  });

  test('a failing STT is a note, the turn still runs', () async {
    await start(
      media: processor(
        stt: (_, {required mime}) async => throw const HttpException('503'),
      ),
    );
    await deliver(
      alice,
      voiceFallback,
      extra: {'media': await uploadMedia(api, bytes(10))},
    );
    await until(() => prompts.isNotEmpty);
    expect(prompts.single, contains('přepis selhal'));
  });

  test('expired voice message: download failure is a note', () async {
    await start(media: processor());
    final media = await uploadMedia(api, bytes(10));
    api.mediaStatus[api.media.keys.single] = 410;
    await deliver(alice, voiceFallback, extra: {'media': media});
    await until(() => prompts.isNotEmpty);
    expect(
      prompts.single,
      contains(
        '[hlasová zpráva 0:10: stažení selhalo: platnost na serveru vypršela]',
      ),
    );
  });

  test('image goes to Hermes as image input', () async {
    await start(media: processor());
    final png = bytes(500);
    await deliver(
      alice,
      'fallback',
      extra: {
        'media': await uploadMedia(
          api,
          png,
          kind: MediaKind.image,
          name: 'photo.png',
          mime: 'image/png',
          durationMs: null,
          caption: 'co to je?',
        ),
      },
    );
    await until(() => imageTurns.isNotEmpty);
    expect(prompts, isEmpty);
    final (text, images) = imageTurns.single;
    expect(text, endsWith('[obrázek photo.png, 500 B]\nco to je?'));
    expect(images.single.mime, 'image/png');
    expect(images.single.bytes, png);
    expect(images.single.toContentPart(), {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'},
    });
  });

  test('image without a multimodal backend is saved as a file', () async {
    await start(media: processor(), withImages: false);
    await deliver(
      alice,
      'fallback',
      extra: {
        'media': await uploadMedia(
          api,
          bytes(500),
          kind: MediaKind.image,
          name: 'photo.png',
          mime: 'image/png',
          durationMs: null,
        ),
      },
    );
    await until(() => prompts.isNotEmpty);
    expect(
      prompts.single,
      contains('[obrázek: photo.png, 500 B, image/png, ${mediaDir()}/'),
    );
    expect(
      File(prompts.single.split(', ').last.replaceAll(']', '')).existsSync(),
      isTrue,
    );
  });

  test('old inline photo (type: file) also goes as image input', () async {
    await start(media: processor());
    final jpg = bytes(800);
    await deliver(
      alice,
      jsonEncode({
        'name': 'IMG_1.jpg',
        'data': base64Encode(jpg),
        'caption': 'hele',
      }),
      extra: {'type': 'file'},
    );
    await until(() => imageTurns.isNotEmpty);
    expect(imageTurns.single.$1, endsWith('[obrázek IMG_1.jpg, 800 B]\nhele'));
    expect(imageTurns.single.$2.single.mime, 'image/jpeg');
    expect(imageTurns.single.$2.single.bytes, jpg);
  });

  test('video is saved; metadata and path reach the agent', () async {
    await start(media: processor());
    final video = bytes(5000);
    await deliver(
      alice,
      'fallback',
      extra: {
        'media': await uploadMedia(
          api,
          video,
          kind: MediaKind.video,
          name: 'clip.mp4',
          mime: 'video/mp4',
          durationMs: 4000,
          caption: 'koukni',
        ),
      },
    );
    await until(() => prompts.isNotEmpty);
    final match = RegExp(
      r'\[soubor: clip\.mp4, 5\.0 KB, video/mp4, ([^\]]+)\]\nkoukni$',
    ).firstMatch(prompts.single);
    expect(match, isNotNull, reason: prompts.single);
    expect(await File(match!.group(1)!).readAsBytes(), video);
  });

  test('a file above MEDIA_MAX_BYTES: metadata only, no download', () async {
    await start(media: processor(maxFileBytes: 1000));
    await deliver(
      alice,
      'fallback',
      extra: {
        'media': await uploadMedia(
          api,
          bytes(2000),
          kind: MediaKind.file,
          name: 'big.zip',
          mime: 'application/zip',
          durationMs: null,
        ),
      },
    );
    await until(() => prompts.isNotEmpty);
    expect(
      prompts.single,
      contains(
        '[soubor: big.zip, 2.0 KB, application/zip, nestaženo: nad limit '
        '1.0 KB]',
      ),
    );
    expect(api.requests.where((r) => r.startsWith('GET /media')), isEmpty);
  });

  test('a bot\'s file in a group: metadata only, nothing fetched', () async {
    await start(media: processor());
    // The bot must have spoken in the group for the peer to have a session.
    await deliver(
      peer,
      'fallback @Hermes',
      group: groupId,
      extra: {
        'mentions': [bot.deviceId],
        'media': await uploadMedia(
          api,
          bytes(10),
          kind: MediaKind.file,
          name: 'r.pdf',
          mime: 'application/pdf',
          durationMs: null,
        ),
      },
    );
    await until(() => prompts.isNotEmpty);
    expect(prompts.single, contains('[soubor: r.pdf, 10 B, application/pdf]'));
    expect(api.requests.where((r) => r.startsWith('GET /media')), isEmpty);
  });

  test('without a media processor the fallback text goes through', () async {
    await start();
    await deliver(
      alice,
      voiceFallback,
      extra: {'media': await uploadMedia(api, bytes(10))},
    );
    await until(() => prompts.isNotEmpty);
    expect(prompts.single, endsWith(voiceFallback));
    expect(transcribed, isEmpty);
  });

  test('cleanup removes folders older than the retention', () async {
    final media = processor();
    await start(media: media);
    await deliver(
      alice,
      'fallback',
      extra: {
        'media': await uploadMedia(
          api,
          bytes(10),
          kind: MediaKind.file,
          name: 'a.txt',
          mime: 'text/plain',
          durationMs: null,
        ),
      },
    );
    await until(() => prompts.isNotEmpty);
    expect(Directory(mediaDir()).listSync(), hasLength(1));
    expect(await media.cleanup(), 0);
    expect(
      await media.cleanup(now: DateTime.now().add(const Duration(days: 8))),
      1,
    );
    expect(Directory(mediaDir()).listSync(), isEmpty);
  });

  test('an owner\'s reaction in the app wire format reaches Hermes', () async {
    await runBridge(
      bot,
      allowedHandles: {'CT-AAAA-0001'},
      stream: stream,
      progress: ProgressSettings.never,
      media: processor(),
      log: logs.add,
    );
    await deliver(alice, 'deploy');
    await until(() => prompts.length == 1);
    final reply = await alice.readPayload(
      bot.deviceId,
      (hub.calls('SendReliableDirectFanout').last[3]
          as Map<String, String>)[alice.id]!,
    );
    await deliver(
      alice,
      ReactionPayload(targetId: reply['id'] as String, emoji: '👍').encode(),
      extra: {
        'type': reactionType,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    );
    await until(() => prompts.length == 2);
    expect(
      prompts.last,
      startsWith(
        '[from CT-AAAA-0001] [reaction 👍 to your message: "answer 1"]',
      ),
    );
    expect(logs, contains('Reaction 👍 from CT-AAAA-0001 passed to Hermes.'));
  });

  group('HermesClient with images', () {
    late HttpServer server;
    final bodies = <Object?>[];

    setUp(() async {
      bodies.clear();
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        final body = await utf8.decodeStream(request);
        if (request.uri.path.endsWith('/chat')) bodies.add(jsonDecode(body));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'message': {'role': 'assistant', 'content': 'red'},
          }),
        );
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('sends text + image_url parts; plain text stays a string', () async {
      final client = HermesClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'k',
        stream: false,
      );
      final img = Uint8List.fromList([1, 2, 3]);
      final events = await client
          .chat(
            'what colour?',
            conversationId: 'c1',
            images: [HermesImage(mime: 'image/png', bytes: img)],
          )
          .toList();
      expect((events.single as HermesCompleted).content, 'red');
      expect((bodies.single as Map)['message'], [
        {'type': 'text', 'text': 'what colour?'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,AQID'},
        },
      ]);
      await client.chat('hi', conversationId: 'c1').toList();
      expect((bodies.last as Map)['message'], 'hi');
      client.close();
    });
  });

  group('ElevenLabsTranscriber', () {
    late HttpServer server;
    late Map<String, Object?> seen;
    var status = 200;

    setUp(() async {
      status = 200;
      seen = {};
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        seen['path'] = request.uri.path;
        seen['key'] = request.headers.value('xi-api-key');
        seen['type'] = request.headers.contentType?.mimeType;
        seen['body'] = latin1.decode(
          await request.fold<List<int>>([], (a, b) => a..addAll(b)),
        );
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'language_code': 'ces', 'text': ' Ahoj '}),
        );
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('multipart upload with model and file; returns text', () async {
      final stt = ElevenLabsTranscriber(
        apiKey: 'secret',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final file = File('${dir.path}/a.m4a')..writeAsBytesSync([9, 8, 7]);
      expect(await stt(file, mime: 'audio/mp4'), ' Ahoj ');
      expect(seen['path'], '/v1/speech-to-text');
      expect(seen['key'], 'secret');
      expect(seen['type'], 'multipart/form-data');
      final body = seen['body'] as String;
      expect(body, contains('name="model_id"\r\n\r\nscribe_v2\r\n'));
      expect(body, contains('Content-Type: audio/mp4\r\n\r\n\x09\x08\x07\r\n'));
      expect(body, isNot(contains('language_code')));
      stt.close();
    });

    test('a non-200 answer throws', () async {
      status = 401;
      final stt = ElevenLabsTranscriber(
        apiKey: 'bad',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final file = File('${dir.path}/a.m4a')..writeAsBytesSync([1]);
      await expectLater(
        stt(file, mime: 'audio/mp4'),
        throwsA(isA<HttpException>()),
      );
      stt.close();
    });
  });
}
