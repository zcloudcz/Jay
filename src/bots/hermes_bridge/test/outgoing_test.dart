import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/media_api.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';

/// Files and voice in replies (README "Sending files and voice replies"):
/// directive parsing, root enforcement, voice decisions, TTS, and whole
/// turns with real crypto, a fake hub, a fake Hermes and a fake TTS.
void main() {
  group('parseOutgoingDirectives', () {
    OutgoingDirectives parse(String text, {Set<String> existing = const {}}) =>
        parseOutgoingDirectives(
          text,
          exists: existing.contains,
          home: '/home/u',
        );

    test('no directive: the reply comes back unchanged', () {
      const reply = 'Hotovo.\n\n  - bod 1\n';
      final r = parse(reply);
      expect(r.text, reply);
      expect(r.files, isEmpty);
      expect(r.voice, isFalse);
    });

    test('MEDIA lines, inline tags, [file:] and [voice:] are taken out', () {
      final r = parse(
        'Tady je report.\n'
        'MEDIA:/tmp/a/report.pdf\n'
        'A graf MEDIA:/tmp/a/chart.png.\n'
        '[file: /tmp/a/data.csv]\n'
        'Nahravka [voice:/tmp/a/note.mp3] hotova',
      );
      expect(r.files, const [
        FileRef('/tmp/a/report.pdf'),
        FileRef('/tmp/a/chart.png'),
        FileRef('/tmp/a/data.csv'),
        FileRef('/tmp/a/note.mp3', voice: true),
      ]);
      expect(r.text, 'Tady je report.\nA graf\nNahravka  hotova');
    });

    test('[voice] asks for a spoken answer and is stripped', () {
      final r = parse('[voice]\nAhoj, tady je odpoved.');
      expect(r.voice, isTrue);
      expect(r.text, 'Ahoj, tady je odpoved.');
      expect(parse('Ahoj [VOICE]').voice, isTrue);
    });

    test('Hermes [[audio_as_voice]] makes audio files voice, not images', () {
      final r = parse(
        '[[audio_as_voice]]\nMEDIA:/x/tts.mp3\nMEDIA:/x/pic.png\n[[as_document]]',
      );
      expect(r.files, const [
        FileRef('/x/tts.mp3', voice: true),
        FileRef('/x/pic.png'),
      ]);
      expect(r.text, isEmpty);
      expect(r.voice, isFalse);
    });

    test('quoted paths and whole lines with spaces', () {
      final r = parse(
        'MEDIA:"/x/my file.pdf"\n'
        'MEDIA:`/x/other file.txt`\n'
        'MEDIA: /x/third one.doc',
        existing: {'/x/third one.doc'},
      );
      expect(r.files.map((f) => f.path), [
        '/x/my file.pdf',
        '/x/other file.txt',
        '/x/third one.doc',
      ]);
    });

    test('~/ is expanded, duplicates are sent once', () {
      final r = parse('MEDIA:~/out/a.png\nznovu MEDIA:~/out/a.png');
      expect(r.files, const [FileRef('/home/u/out/a.png')]);
    });

    test('code blocks, inline code and quotes are never delivered', () {
      const reply =
          'Syntaxe je `MEDIA:/path` nebo:\n'
          '```\nMEDIA:/etc/passwd\n[voice]\n```\n'
          '> MEDIA:/etc/shadow\n'
          'Konec.';
      final r = parse(reply);
      expect(r.files, isEmpty);
      expect(r.voice, isFalse);
      expect(r.text, reply);
    });
  });

  group('FileRoots', () {
    late Directory dir;
    late String root;
    late String outside;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hermes_bridge_roots');
      root = '${dir.path}/root';
      outside = '${dir.path}/outside';
      await Directory('$root/sub').create(recursive: true);
      await Directory(outside).create();
      File('$root/sub/ok.txt').writeAsStringSync('ok');
      File('$outside/secret.txt').writeAsStringSync('secret');
    });
    tearDown(() => dir.delete(recursive: true));

    FileRoots roots({int maxBytes = 1000}) =>
        FileRoots([root, '${dir.path}/missing'], maxBytes: maxBytes);

    Future<String> refused(String path, {int maxBytes = 1000}) async {
      try {
        await roots(maxBytes: maxBytes).check(path);
      } on FileRefused catch (e) {
        return e.reason;
      }
      fail('$path was accepted');
    }

    test('a file inside a root is accepted with its real path', () async {
      expect(await roots().check('$root/sub/ok.txt'), '$root/sub/ok.txt');
    });

    test('outside, ../ escapes and relative paths are refused', () async {
      expect(await refused('$outside/secret.txt'), 'mimo povolené složky');
      expect(
        await refused('$root/sub/../../outside/secret.txt'),
        'mimo povolené složky',
      );
      expect(await refused('sub/ok.txt'), 'cesta není absolutní');
      expect(await refused('$root/nope.txt'), 'soubor neexistuje');
      expect(await refused('$root/sub'), 'soubor neexistuje');
    });

    test('a symlink inside a root that points out is refused', () async {
      await Link('$root/link.txt').create('$outside/secret.txt');
      await Link('$root/dirlink').create(outside);
      expect(await refused('$root/link.txt'), 'mimo povolené složky');
      expect(await refused('$root/dirlink/secret.txt'), 'mimo povolené složky');
    });

    test('a symlink within the root and a symlinked root work', () async {
      await Link('$root/alias.txt').create('$root/sub/ok.txt');
      expect(await roots().check('$root/alias.txt'), '$root/sub/ok.txt');
      await Link('${dir.path}/rootlink').create(root);
      final viaLink = FileRoots(['${dir.path}/rootlink'], maxBytes: 1000);
      expect(await viaLink.check('$root/sub/ok.txt'), '$root/sub/ok.txt');
    });

    test('a root prefix is not a root (root2 is not under root)', () async {
      await Directory('${root}2').create();
      File('${root}2/x.txt').writeAsStringSync('x');
      expect(await refused('${root}2/x.txt'), 'mimo povolené složky');
    });

    test('above the size cap is refused', () async {
      File('$root/big.bin').writeAsBytesSync(List.filled(2000, 1));
      expect(await refused('$root/big.bin'), startsWith('nad limit'));
    });
  });

  group('voice decisions', () {
    test('parseVoiceReplyMode', () {
      expect(parseVoiceReplyMode(null), VoiceReplyMode.auto);
      expect(parseVoiceReplyMode(' Always '), VoiceReplyMode.always);
      expect(parseVoiceReplyMode('off'), VoiceReplyMode.off);
      expect(() => parseVoiceReplyMode('sometimes'), throwsFormatException);
    });

    test('wantsVoiceReply', () {
      bool want(
        VoiceReplyMode m, {
        bool voice = false,
        bool asked = false,
        bool directive = false,
      }) => wantsVoiceReply(
        m,
        userSentVoice: voice,
        userAskedForVoice: asked,
        agentDirective: directive,
      );
      expect(want(VoiceReplyMode.auto), isFalse);
      expect(want(VoiceReplyMode.auto, voice: true), isTrue);
      expect(want(VoiceReplyMode.auto, asked: true), isTrue);
      expect(want(VoiceReplyMode.auto, directive: true), isTrue);
      expect(want(VoiceReplyMode.always), isTrue);
      expect(
        want(VoiceReplyMode.off, voice: true, asked: true, directive: true),
        isFalse,
      );
    });

    test('asksForVoiceReply', () {
      for (final yes in [
        'odpověz mi hlasovkou',
        'Pošli mi to hlasovou zprávou',
        'namluv mi to',
        'please reply with a voice message',
      ]) {
        expect(asksForVoiceReply(yes), isTrue, reason: yes);
      }
      for (final no in ['jak se máš', 'poslal jsem ti zprávu', 'voices']) {
        expect(asksForVoiceReply(no), isFalse, reason: no);
      }
    });

    test('speechText drops code, links and markdown; cuts at a sentence', () {
      expect(
        speechText(
          '# Stav\n**Hotovo.** Viz [odkaz](https://x.cz) a https://y.cz\n'
          '```\ncode\n```\n- bod `a`',
        ),
        'Stav\nHotovo. Viz odkaz a\nbod a',
      );
      expect(
        speechText(
          'Prvni veta. Druha veta je delsi. Treti veta je jeste delsi.',
          maxChars: 40,
        ),
        'Prvni veta. Druha veta je delsi.',
      );
    });
  });

  group('ElevenLabsTts', () {
    late HttpServer server;
    final seen = <(String, String?, Map<String, dynamic>)>[];
    var status = 200;

    setUp(() async {
      seen.clear();
      status = 200;
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decodeStream(request));
        seen.add((
          request.uri.toString(),
          request.headers.value('xi-api-key'),
          body as Map<String, dynamic>,
        ));
        request.response.statusCode = status;
        if (status == 200) {
          request.response.add([0x49, 0x44, 0x33, 1, 2, 3]);
        } else {
          request.response.write('{"detail":{"status":"quota_exceeded"}}');
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('posts text + model to the voice, writes the audio', () async {
      final dir = await Directory.systemTemp.createTemp('tts');
      addTearDown(() => dir.delete(recursive: true));
      final tts = ElevenLabsTts(
        apiKey: 'k',
        voiceId: 'voice123',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final file = await tts('Ahoj', '${dir.path}/a.mp3');
      expect(await file.readAsBytes(), [0x49, 0x44, 0x33, 1, 2, 3]);
      expect(
        seen.single.$1,
        '/v1/text-to-speech/voice123?output_format=mp3_44100_128',
      );
      expect(seen.single.$2, 'k');
      expect(seen.single.$3, {'text': 'Ahoj', 'model_id': 'eleven_v4'});
      status = 401;
      await expectLater(
        tts('Ahoj', '${dir.path}/b.mp3'),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('quota_exceeded'),
          ),
        ),
      );
      tts.close();
    });
  });

  group('turns and /send', () {
    late Directory dir;
    late FakeApi api;
    late FakeHub hub;
    late FakeUser alice;
    late CallTypeBot bot;
    late String files;
    final prompts = <String>[];
    final decrypted = <Map<String, dynamic>>[];
    final spoken = <String>[];
    final logs = <String>[];
    var answer = 'odpoved';
    var ttsFails = false;

    Stream<HermesEvent> stream(String text, {required String conversationId}) {
      prompts.add(text);
      return Stream.value(HermesCompleted(answer));
    }

    Future<File> fakeTts(String text, String outPath) async {
      if (ttsFails) throw const HttpException('ElevenLabs TTS: HTTP 401');
      spoken.add(text);
      return File(outPath)..writeAsBytesSync(utf8.encode('mp3:$text'));
    }

    setUp(() async {
      prompts.clear();
      decrypted.clear();
      spoken.clear();
      logs.clear();
      answer = 'odpoved';
      ttsFails = false;
      dir = await Directory.systemTemp.createTemp('hermes_bridge_outgoing');
      files = '${dir.path}/files';
      await Directory(files).create();
      api = await FakeApi.start();
      hub = FakeHub();
      alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
      api.handles['CT-AAAA-0001'] = alice.id;
      api.keyBundles[alice.id] = await alice.keyBundle();
      bot = await CallTypeBot.start(
        apiBaseUrl: api.url,
        storePath: '${dir.path}/bot.store',
        storeKeyBase64: testStoreKey,
        transportFactory: (_, _) => hub,
        log: logs.add,
        sendRetryDelay: Duration.zero,
      );
      bot.mediaTools = BotMediaTools.disabled();
    });

    tearDown(() async {
      await bot.close();
      await alice.close();
      await api.close();
      await dir.delete(recursive: true);
    });

    OutgoingMedia outgoing({
      VoiceReplyMode mode = VoiceReplyMode.auto,
      bool withText = true,
      bool tts = true,
    }) => OutgoingMedia(
      roots: FileRoots([files], maxBytes: 1 << 20),
      ttsDir: '${dir.path}/tts',
      speak: tts ? fakeTts : null,
      voiceMode: mode,
      voiceWithText: withText,
      log: logs.add,
    );

    Future<HermesBridge> start({OutgoingMedia? out, bool media = false}) =>
        runBridge(
          bot,
          allowedHandles: {'CT-AAAA-0001'},
          stream: stream,
          progress: ProgressSettings.never,
          outgoing: out,
          media: media
              ? MediaProcessor(
                  settings: MediaSettings(dir: '${dir.path}/media'),
                  transcribe: (audio, {required mime}) async =>
                      'odpovez mi prosim',
                  log: logs.add,
                )
              : null,
          log: logs.add,
        );

    /// Everything alice decrypted from the bot, in order. Each envelope is
    /// decrypted once (a ratchet message cannot be opened twice).
    Future<List<Map<String, dynamic>>> received() async {
      final calls = hub.calls('SendReliableDirectFanout');
      for (var i = decrypted.length; i < calls.length; i++) {
        decrypted.add(
          await alice.readPayload(
            bot.deviceId,
            (calls[i][3] as Map<String, String>)[alice.id]!,
          ),
        );
      }
      return List.of(decrypted);
    }

    Future<void> say(
      String text, {
      Map<String, dynamic> extra = const {},
    }) async {
      final before = hub.calls('AcknowledgeMessage').length;
      hub.deliver(
        await alice.messageTo(
          bot.deviceId,
          api.botBundle,
          text,
          to: bot.deviceId,
          extra: extra,
        ),
      );
      await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
    }

    Future<Uint8List> download(Map<String, dynamic> payload) =>
        BotAttachment.fromMedia(
          payload['media'],
          ApiClient(baseUrl: api.url).downloadMedia,
        )!.readBytes(maxBytes: 1 << 20);

    test('MEDIA line + short text: one media message with caption', () async {
      File('$files/report.pdf').writeAsStringSync('PDF-DATA');
      answer = 'Tady je report.\nMEDIA:$files/report.pdf';
      await start(out: outgoing());
      await say('posli report');
      final sent = await received();
      expect(sent, hasLength(1));
      final media = MediaInfo.tryParse(sent.single['media'])!;
      expect(media.name, 'report.pdf');
      expect(media.caption, 'Tady je report.');
      expect(utf8.decode(await download(sent.single)), 'PDF-DATA');
      // First turn of the conversation: the agent learned the syntax.
      expect(prompts.single, contains(filesDirectiveHint));
      expect(prompts.single, isNot(contains(voiceReplyHint)));
    });

    test('long text goes first as a message, then the files', () async {
      File('$files/a.txt').writeAsStringSync('A');
      File('$files/b.txt').writeAsStringSync('B');
      answer = 'Dve prilohy.\n[file:$files/a.txt]\n[file:$files/b.txt]';
      await start(out: outgoing());
      await say('posli');
      final sent = await received();
      expect(sent.map((p) => p['media'] == null ? p['body'] : 'media'), [
        'Dve prilohy.',
        'media',
        'media',
      ]);
      expect(MediaInfo.tryParse(sent[1]['media'])!.caption, isNull);
    });

    test('a file outside the roots is not sent; the owner is told', () async {
      final secret = File('${dir.path}/secret.txt')..writeAsStringSync('x');
      await Link('$files/link.txt').create(secret.path);
      answer = 'Tady.\nMEDIA:${secret.path}\nMEDIA:$files/link.txt';
      await start(out: outgoing());
      await say('posli');
      final sent = await received();
      expect(sent.map((p) => p['body']), [
        'Tady.',
        'Soubor se nepodařilo poslat: secret.txt: mimo povolené složky; '
            'link.txt: mimo povolené složky',
      ]);
      expect(api.uploads, isEmpty);
      expect(logs.where((l) => l.contains('refused')), hasLength(2));
    });

    test('voice message in: text answer plus a spoken voice reply', () async {
      answer = 'Mleko koupim zitra.';
      await start(out: outgoing(), media: true);
      final media = await uploadMedia(api, Uint8List.fromList([1, 2, 3]));
      await say('🎤 Voice message (0:10).', extra: {'media': media});
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      expect(prompts.single, contains(voiceReplyHint));
      final sent = await received();
      expect(sent[0]['body'], 'Mleko koupim zitra.');
      final voice = MediaInfo.tryParse(sent[1]['media'])!;
      expect(voice.kind, MediaKind.voice);
      expect(voice.mime, 'audio/mpeg'); // no ffmpeg in this test
      expect(utf8.decode(await download(sent[1])), 'mp3:Mleko koupim zitra.');
      expect(spoken, ['Mleko koupim zitra.']);
      // The TTS file is gone after sending.
      expect(Directory('${dir.path}/tts').listSync(), isEmpty);
    });

    test('[voice] directive in auto mode speaks a text turn', () async {
      answer = '[voice]\nTady je hlasova odpoved.';
      await start(out: outgoing());
      await say('jak se mas');
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      final sent = await received();
      expect(sent[0]['body'], 'Tady je hlasova odpoved.');
      expect(MediaInfo.tryParse(sent[1]['media'])!.kind, MediaKind.voice);
    });

    test('the owner asking for a voice reply turns it on', () async {
      await start(out: outgoing());
      await say('odpověz mi hlasovkou');
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      expect(prompts.single, contains(voiceReplyHint));
      expect(spoken, ['odpoved']);
    });

    test('VOICE_REPLY_MODE=off strips [voice] and sends text only', () async {
      answer = '[voice]\nJen text.';
      await start(out: outgoing(mode: VoiceReplyMode.off));
      await say('odpověz hlasovkou');
      final sent = await received();
      expect(sent.map((p) => p['body']), ['Jen text.']);
      expect(spoken, isEmpty);
    });

    test('VOICE_REPLY_MODE=always speaks every owner turn', () async {
      await start(out: outgoing(mode: VoiceReplyMode.always));
      await say('ahoj');
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      expect(spoken, ['odpoved']);
    });

    test('voice only: no text; a failing TTS falls back to text', () async {
      await start(out: outgoing(withText: false));
      await say('odpověz hlasovkou');
      await until(() => hub.calls('SendReliableDirectFanout').isNotEmpty);
      var sent = await received();
      expect(sent, hasLength(1));
      expect(sent.single['media'], isNotNull);
      ttsFails = true;
      await say('odpověz hlasovkou znovu');
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      sent = await received();
      expect(sent.last['body'], 'odpoved');
      expect(
        logs.any((l) => l.contains('Voice reply') && l.contains('401')),
        isTrue,
      );
    });

    test('without TTS no voice reply happens even when asked', () async {
      await start(out: outgoing(tts: false));
      await say('odpověz hlasovkou');
      final sent = await received();
      expect(sent.map((p) => p['body']), ['odpoved']);
      expect(prompts.single, isNot(contains(voiceReplyHint)));
    });

    test(
      'without outgoing media a MEDIA line stays text (old behaviour)',
      () async {
        answer = 'MEDIA:$files/x.png';
        await start();
        await say('ahoj');
        expect((await received()).single['body'], 'MEDIA:$files/x.png');
        expect(prompts.single, isNot(contains(filesDirectiveHint)));
      },
    );

    test('/send with a file, a voice text, and refusals', () async {
      final bridge = await start(out: outgoing());
      File('$files/plan.txt').writeAsStringSync('PLAN');
      expect(
        await bridge.sendMediaFromLocal(
          LocalMediaRequest(
            to: 'CT-AAAA-0001',
            file: '$files/plan.txt',
            caption: 'plan',
            text: 'Posilam plan.',
          ),
        ),
        SendOutcome.sent,
      );
      var sent = await received();
      expect(sent[0]['body'], 'Posilam plan.');
      expect(MediaInfo.tryParse(sent[1]['media'])!.caption, 'plan');
      expect(utf8.decode(await download(sent[1])), 'PLAN');

      expect(
        await bridge.sendMediaFromLocal(
          const LocalMediaRequest(
            to: 'CT-AAAA-0001',
            text: 'Bridge umi hlas.',
            voice: true,
          ),
        ),
        SendOutcome.sent,
      );
      sent = await received();
      expect(sent, hasLength(3));
      expect(MediaInfo.tryParse(sent[2]['media'])!.kind, MediaKind.voice);
      expect(spoken.last, 'Bridge umi hlas.');

      File('${dir.path}/out.txt').writeAsStringSync('no');
      expect(
        await bridge.sendMediaFromLocal(
          LocalMediaRequest(to: 'CT-AAAA-0001', file: '${dir.path}/out.txt'),
        ),
        SendOutcome.fileNotAllowed,
      );
      expect(
        await bridge.sendMediaFromLocal(
          LocalMediaRequest(to: 'CT-ZZZZ-9999', file: '$files/plan.txt'),
        ),
        SendOutcome.forbidden,
      );
      expect(
        await bridge.sendMediaFromLocal(
          LocalMediaRequest(
            to: 'channel:CH-AAAA-0001',
            file: '$files/plan.txt',
          ),
        ),
        SendOutcome.badTarget,
      );
      File('$files/big.bin').writeAsBytesSync(List.filled((1 << 20) + 1, 0));
      expect(
        await bridge.sendMediaFromLocal(
          LocalMediaRequest(to: 'CT-AAAA-0001', file: '$files/big.bin'),
        ),
        SendOutcome.fileTooLarge,
      );
      expect(hub.calls('SendReliableDirectFanout'), hasLength(3));
    });

    test('/send voice without TTS is media_unavailable', () async {
      final bridge = await start(out: outgoing(tts: false));
      expect(
        await bridge.sendMediaFromLocal(
          const LocalMediaRequest(to: 'CT-AAAA-0001', text: 'x', voice: true),
        ),
        SendOutcome.mediaUnavailable,
      );
    });
  });

  group('POST /send with a file', () {
    late HttpServer server;
    late HttpClient client;
    final requests = <LocalMediaRequest>[];
    var outcome = SendOutcome.sent;

    Future<HttpServer> serve({bool media = true}) async =>
        (await startSendEndpoint(
          key: 'k',
          port: 0,
          send: (to, text) async => SendOutcome.sent,
          sendMedia: media
              ? (r) async {
                  requests.add(r);
                  return outcome;
                }
              : null,
          log: (_) {},
        ))!;

    setUp(() async {
      requests.clear();
      outcome = SendOutcome.sent;
      server = await serve();
      client = HttpClient();
    });
    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    Future<(int, String)> post(Object body, [HttpServer? on]) async {
      final request = await client.post(
        '127.0.0.1',
        (on ?? server).port,
        '/send',
      );
      request.headers.set('authorization', 'Bearer k');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      return (response.statusCode, await utf8.decodeStream(response));
    }

    test('valid bodies reach sendMedia', () async {
      expect(
        (await post({
          'to': 'CT-AAAA-0001',
          'file': '/x/a.pdf',
          'kind': 'file',
          'caption': 'c',
        })).$1,
        202,
      );
      expect(
        (await post({'to': 'CT-AAAA-0001', 'text': 'ahoj', 'voice': true})).$1,
        202,
      );
      expect(requests[0].file, '/x/a.pdf');
      expect(requests[0].kind, MediaKind.file);
      expect(requests[0].caption, 'c');
      expect(requests[1].voice, isTrue);
      expect(requests[1].file, isNull);
    });

    test('bad bodies are 400 and never reach sendMedia', () async {
      for (final body in [
        {'to': 'CT-AAAA-0001', 'file': 'relative.txt'},
        {'to': 'CT-AAAA-0001', 'file': '/x', 'kind': 'sticker'},
        {'to': 'CT-AAAA-0001', 'voice': true},
        {'to': 'CT-AAAA-0001', 'voice': 'yes', 'text': 'x'},
        {'to': 'CT-AAAA-0001', 'caption': 'only a caption'},
        {'to': '', 'file': '/x'},
      ]) {
        expect((await post(body)).$1, 400, reason: '$body');
      }
      expect(requests, isEmpty);
    });

    test('outcomes map to statuses', () async {
      for (final (o, status, error) in [
        (SendOutcome.fileNotAllowed, 403, 'file_not_allowed'),
        (SendOutcome.fileTooLarge, 413, 'file_too_large'),
        (SendOutcome.mediaUnavailable, 503, 'media_unavailable'),
        (SendOutcome.badTarget, 400, 'bad_target'),
      ]) {
        outcome = o;
        final (code, body) = await post({'to': 'CT-AAAA-0001', 'file': '/x'});
        expect(code, status);
        expect(jsonDecode(body), {'error': error});
      }
    });

    test('without sendMedia a file request is files_unsupported', () async {
      final plain = await serve(media: false);
      addTearDown(() => plain.close(force: true));
      final (code, body) = await post({
        'to': 'CT-AAAA-0001',
        'file': '/x',
      }, plain);
      expect(code, 400);
      expect(jsonDecode(body), {'error': 'files_unsupported'});
      // Text-only requests are unchanged.
      expect((await post({'to': 'CT-AAAA-0001', 'text': 'hi'}, plain)).$1, 202);
    });
  });
}
