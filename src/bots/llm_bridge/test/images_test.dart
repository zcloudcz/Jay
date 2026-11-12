import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

import 'support/fake_llm_server.dart';
import 'support/fakes.dart';

final png = pngBytes;
final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

ChatImage pngImage([String name = 'cat.png']) =>
    ChatImage(bytes: png, mediaType: 'image/png', name: name);

IncomingFile incoming({
  String name = 'photo.jpg',
  String mime = 'image/jpeg',
  int? size,
  bool isImage = true,
  Uint8List? bytes,
  Object? error,
  List<int>? reads,
}) {
  final data = bytes ?? jpeg;
  return IncomingFile(
    name: name,
    mime: mime,
    size: size ?? data.length,
    isImage: isImage,
    read: (max) async {
      reads?.add(max);
      if (error != null) throw error;
      return data;
    },
  );
}

void main() {
  group('sniffImageType', () {
    test('the four supported types by magic bytes', () {
      expect(sniffImageType(jpeg), 'image/jpeg');
      expect(sniffImageType(png), 'image/png');
      expect(sniffImageType(ascii.encode('GIF89a....')), 'image/gif');
      expect(sniffImageType(ascii.encode('GIF87a....')), 'image/gif');
      expect(
        sniffImageType(ascii.encode('RIFF\x00\x00\x00\x00WEBPVP8 ')),
        'image/webp',
      );
    });

    test('anything else is null (HEIC, PDF, text, too short)', () {
      expect(sniffImageType(ascii.encode('%PDF-1.7')), isNull);
      expect(sniffImageType(ascii.encode('\x00\x00\x00\x18ftypheic')), isNull);
      expect(sniffImageType(ascii.encode('hello')), isNull);
      expect(sniffImageType(const [0xFF, 0xD8]), isNull);
      expect(sniffImageType(const []), isNull);
    });
  });

  group('readIncomingImage (spec M4/M6)', () {
    test('an image is read with the cap and typed from its bytes', () async {
      final reads = <int>[];
      // Declared PNG, really a JPEG: the bytes win.
      final r = await readIncomingImage(
        incoming(name: 'x.png', mime: 'image/png', reads: reads),
        maxBytes: 1000,
      );
      expect(r, isA<AcceptedImage>());
      final image = (r as AcceptedImage).image;
      expect(image.mediaType, 'image/jpeg');
      expect(image.name, 'x.png');
      expect(reads, [1000]);
    });

    test('not an image: polite text, nothing downloaded', () async {
      final reads = <int>[];
      final r = await readIncomingImage(
        incoming(
          name: 'voice.m4a',
          mime: 'audio/mp4',
          isImage: false,
          reads: reads,
        ),
      );
      expect((r as RefusedFile).reply, contains('cannot open "voice.m4a"'));
      expect(r.reply, contains('JPEG, PNG, GIF, WebP up to 5 MB'));
      expect(reads, isEmpty);
    });

    test('over the cap by declared size: refused before download', () async {
      final reads = <int>[];
      final r = await readIncomingImage(
        incoming(size: 6 * 1024 * 1024, reads: reads),
      );
      expect((r as RefusedFile).reply, contains('too large'));
      expect(reads, isEmpty);
    });

    test('an image of another type (HEIC) is refused after reading', () async {
      final r = await readIncomingImage(
        incoming(
          name: 'a.heic',
          mime: 'image/heic',
          bytes: Uint8List.fromList(ascii.encode('\x00\x00\x00\x18ftypheic')),
        ),
      );
      expect((r as RefusedFile).reply, contains('cannot open "a.heic"'));
    });

    test('expired, too large while reading, broken', () async {
      expect(
        ((await readIncomingImage(incoming(error: const IncomingFileExpired())))
                as RefusedFile)
            .reply,
        ImageTexts.expired,
      );
      expect(
        ((await readIncomingImage(
                  incoming(error: const IncomingFileTooLarge()),
                ))
                as RefusedFile)
            .reply,
        contains('too large'),
      );
      final logs = <String>[];
      expect(
        ((await readIncomingImage(
                  incoming(error: StateError('tampered')),
                  log: logs.add,
                ))
                as RefusedFile)
            .reply,
        ImageTexts.broken,
      );
      expect(logs.single, contains('tampered'));
    });
  });

  group('request bodies with images (spec M5)', () {
    final conversation = [
      const ChatTurn.user('earlier'),
      const ChatTurn.assistant('ok'),
      ChatTurn.user('[image: cat.png]\nwhat is it?', images: [pngImage()]),
    ];

    test('anthropic: base64 image block before the text', () {
      final body = AnthropicProvider(
        apiKey: 'k',
        model: 'm',
      ).requestBody(conversation, 's');
      final messages = body['messages'] as List;
      expect(messages[0], {'role': 'user', 'content': 'earlier'});
      expect(messages[2], {
        'role': 'user',
        'content': [
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/png',
              'data': base64Encode(png),
            },
          },
          {'type': 'text', 'text': '[image: cat.png]\nwhat is it?'},
        ],
      });
    });

    test('openai: text part then image_url with a data URL', () {
      final body = OpenAiProvider(model: 'm').requestBody(conversation, 's');
      final messages = body['messages'] as List;
      expect(messages[1], {'role': 'user', 'content': 'earlier'});
      expect(messages[3], {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '[image: cat.png]\nwhat is it?'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'},
          },
        ],
      });
    });

    test('merged user turns keep their images', () {
      final turns = normalizeTurns([
        ChatTurn.user('a', images: [pngImage('a.png')]),
        ChatTurn.user('b', images: [pngImage('b.png')]),
      ]);
      expect(turns.single.images.map((i) => i.name), ['a.png', 'b.png']);
    });

    test('a real anthropic request carries the image', () async {
      final server = await FakeLlmServer.start();
      addTearDown(server.close);
      server.answers.add(FakeAnswer.sse(anthropicStream(['A cat.'])));
      final p = AnthropicProvider(apiKey: 'k', model: 'm', baseUrl: server.url);
      addTearDown(p.close);
      expect(await p.reply(conversation, system: 's').join(), 'A cat.');
      final content =
          (server.requests.single.body['messages'] as List).last['content']
              as List;
      expect(content.first['source']['data'], base64Encode(png));
    });
  });

  group('bridge with images (spec M4/M7)', () {
    late Directory dir;
    late FakeProvider provider;
    late HistoryStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('llm_images_test');
      provider = FakeProvider();
      store = await HistoryStore.open(
        '${dir.path}/bot.store.llm',
        base64Decode(base64Encode(List.filled(32, 1))),
        cap: 20,
      );
    });
    tearDown(() => dir.delete(recursive: true));

    LlmBridge bridge({ImageGenerator? generator}) => LlmBridge(
      provider: provider,
      history: store,
      displayName: 'Pepa',
      systemPrompt: 'You are Pepa.',
      progressAfter: Duration.zero,
      imageGenerator: generator,
      mediaDir: '${dir.path}/media',
    );

    test(
      'the image goes to the provider, the history keeps a placeholder',
      () async {
        provider.scripts.add(() => answer(['A red square.']));
        final sink = FakeSink();
        await bridge().handle(
          conversationId: 'C1',
          text: 'what is this?',
          sink: sink,
          images: [pngImage()],
        );
        expect(sink.texts, ['A red square.']);
        final sent = provider.calls.single.conversation.single;
        expect(sent.text, '[image: cat.png]\nwhat is this?');
        expect(sent.images.single.bytes, png);
        final remembered = await store.history('C1');
        expect(remembered.first.text, '[image: cat.png]\nwhat is this?');
        expect(remembered.first.images, isEmpty);
        // The stored JSON has no image data.
        expect(
          jsonEncode([for (final t in remembered) t.toJson()]),
          isNot(contains(base64Encode(png))),
        );

        // Next turn: the old image is text only.
        provider.scripts.add(() => answer(['Yes.']));
        await bridge().handle(conversationId: 'C1', text: 'sure?', sink: sink);
        final second = provider.calls.last.conversation;
        expect(second.every((t) => t.images.isEmpty), isTrue);
        expect(second.first.text, '[image: cat.png]\nwhat is this?');
      },
    );

    test(
      'an image without caption is answered, slash text is not a command',
      () async {
        provider.scripts.add(() => answer(['Nice.']));
        final sink = FakeSink();
        await bridge().handle(
          conversationId: 'C1',
          text: '',
          sink: sink,
          senderLabel: 'CT-MEMB-0002',
          images: [pngImage()],
        );
        expect(
          provider.calls.single.conversation.single.text,
          '[from CT-MEMB-0002] [image: cat.png]',
        );
        provider.scripts.add(() => answer(['Fine.']));
        await bridge().handle(
          conversationId: 'C1',
          text: '/new',
          sink: sink,
          images: [pngImage()],
        );
        expect(provider.calls, hasLength(2));
        expect((await store.history('C1')), hasLength(4));
      },
    );

    test('a failed answer stores nothing', () async {
      provider.scripts.add(
        () => Stream.error(const LlmException('model has no vision')),
      );
      final sink = FakeSink();
      await bridge().handle(
        conversationId: 'C1',
        text: 'x',
        sink: sink,
        images: [pngImage()],
      );
      expect(sink.texts.single, contains('model has no vision'));
      expect(await store.history('C1'), isEmpty);
    });

    group('image generation (spec M8)', () {
      test('off: tags stay text, no hint in the system prompt', () async {
        provider.scripts.add(() => answer(['Here [[image: a cat]]']));
        final sink = FakeSink();
        await bridge().handle(conversationId: 'C1', text: 'cat', sink: sink);
        expect(sink.texts, ['Here [[image: a cat]]']);
        expect(sink.files, isEmpty);
        expect(provider.calls.single.system, isNot(contains('[[image:')));
      });

      test('on: tag removed, image generated, sent and deleted', () async {
        final generator = FakeGenerator();
        provider.scripts.add(
          () => answer(['Here you go.\n[[image: a ginger cat on a sofa]]']),
        );
        final sink = FakeSink();
        await bridge(
          generator: generator,
        ).handle(conversationId: 'C1', text: 'draw a cat', sink: sink);
        expect(provider.calls.single.system, contains('[[image:'));
        expect(provider.calls.single.system, startsWith('You are Pepa.'));
        expect(sink.texts, ['Here you go.']);
        expect(generator.prompts, ['a ginger cat on a sofa']);
        expect(sink.files.single.bytes, png);
        expect(sink.files.single.path, startsWith('${dir.path}/media/'));
        expect(File(sink.files.single.path).existsSync(), isFalse);
        expect(
          (await store.history('C1')).last.text,
          'Here you go.\n[image sent: a ginger cat on a sofa]',
        );
      });

      test(
        'only a tag: the placeholder is the text; at most 2 images',
        () async {
          final generator = FakeGenerator();
          provider.scripts.add(
            () => answer(['[[image: one]] [[image: two]] [[image: three]]']),
          );
          final sink = FakeSink();
          await bridge(
            generator: generator,
          ).handle(conversationId: 'C1', text: 'three cats', sink: sink);
          expect(generator.prompts, ['one', 'two']);
          expect(sink.files, hasLength(2));
          expect(sink.texts, ['[image sent: one]\n[image sent: two]']);
        },
      );

      test('a failed generation adds a note, the text still arrives', () async {
        provider.scripts.add(() => answer(['Sure. [[image: x]]']));
        final sink = FakeSink();
        await bridge(
          generator: FakeGenerator(fail: true),
        ).handle(conversationId: 'C1', text: 'draw', sink: sink);
        expect(sink.texts, [
          'Sure.',
          '(I could not create the image: content policy)',
        ]);
        expect(sink.files, isEmpty);
        expect((await store.history('C1')).last.text, contains('could not'));
      });
    });
  });

  group('OpenAiImageGenerator', () {
    late FakeLlmServer server;
    setUp(() async => server = await FakeLlmServer.start());
    tearDown(() => server.close());

    test('POST /images/generations, b64_json decoded', () async {
      server.answers.add(
        FakeAnswer.json({
          'data': [
            {'b64_json': base64Encode(png)},
          ],
        }),
      );
      final g = OpenAiImageGenerator(
        model: 'gpt-image-1',
        apiKey: 'sk-test',
        baseUrl: server.url,
      );
      addTearDown(g.close);
      expect(await g.generate('a cat'), png);
      final r = server.requests.single;
      expect(r.path, '/images/generations');
      expect(r.headers['authorization'], 'Bearer sk-test');
      expect(r.body, {
        'model': 'gpt-image-1',
        'prompt': 'a cat',
        'n': 1,
        'size': '1024x1024',
      });
    });

    test('dall-e asks for b64_json; errors are LlmExceptions', () async {
      expect(
        OpenAiImageGenerator(model: 'dall-e-3').requestBody('p'),
        containsPair('response_format', 'b64_json'),
      );
      server.answers.add(
        FakeAnswer.json({
          'error': {'message': 'Your request was rejected'},
        }, status: 400),
      );
      final g = OpenAiImageGenerator(model: 'gpt-image-1', baseUrl: server.url);
      addTearDown(g.close);
      await expectLater(
        g.generate('x'),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            'Your request was rejected',
          ),
        ),
      );
      server.answers
        ..clear()
        ..add(FakeAnswer.json({'data': []}));
      await expectLater(g.generate('x'), throwsA(isA<LlmException>()));
    });
  });

  group('config', () {
    const base = {
      'CALLTYPE_API_URL': 'https://api.example.invalid/',
      'ALLOWED_HANDLES': 'CT-AAAA-0001',
    };
    LlmConfig parse(Map<String, String> extra) =>
        LlmConfig.fromEnvironment({...base, ...extra});

    test('default prompt says the bot sees images; defaults', () {
      final c = parse({'LLM_PROVIDER': 'anthropic', 'ANTHROPIC_API_KEY': 'k'});
      expect(c.systemPrompt, contains('see images'));
      expect(c.imageModel, isNull);
      expect(c.imageMaxBytes, 5 * 1024 * 1024);
      expect(buildImageGenerator(c), isNull);
    });

    test('LLM_IMAGE_MODEL with openai builds the generator', () {
      final c = parse({
        'LLM_PROVIDER': 'openai',
        'OPENAI_API_KEY': 'k',
        'LLM_IMAGE_MODEL': 'gpt-image-1',
        'BOT_STORE_PATH': '/b/bot.store',
      });
      expect(c.imageModel, 'gpt-image-1');
      expect(c.mediaDir, '/b/bot.store.media');
      expect(
        buildImageGenerator(c),
        isA<OpenAiImageGenerator>().having(
          (g) => g.model,
          'model',
          'gpt-image-1',
        ),
      );
    });

    for (final p in ['anthropic', 'claude-cli', 'codex-cli']) {
      test('LLM_IMAGE_MODEL with $p is a config error', () {
        expect(
          () => parse({
            'LLM_PROVIDER': p,
            'ANTHROPIC_API_KEY': 'k',
            'LLM_IMAGE_MODEL': 'gpt-image-1',
          }),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('only with LLM_PROVIDER=openai'),
            ),
          ),
        );
      });
    }

    test('LLM_IMAGE_MAX_BYTES is capped at 20 MB', () {
      final c = parse({
        'LLM_PROVIDER': 'anthropic',
        'ANTHROPIC_API_KEY': 'k',
        'LLM_IMAGE_MAX_BYTES': '1048576',
      });
      expect(c.imageMaxBytes, 1048576);
      expect(
        () => parse({
          'LLM_PROVIDER': 'anthropic',
          'ANTHROPIC_API_KEY': 'k',
          'LLM_IMAGE_MAX_BYTES': '${21 * 1024 * 1024}',
        }),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  test('extractImageTags', () {
    final r = extractImageTags('A\n\n[[image:  sunset  ]]\n\n\nB [[image: ]]');
    expect(r.prompts, ['sunset']);
    expect(r.text, 'A\n\nB');
  });
}
