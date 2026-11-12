import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:llm_bridge/src/jay_glue.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fakes.dart';

/// The bridge on the REAL bot runtime: real calltype_core crypto on both
/// sides, fake hub + loopback REST (calltype_bot's test helpers).
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser owner;
  late FakeUser stranger;
  late CallTypeBot bot;
  late FakeProvider provider;
  late HistoryStore store;
  late FakeGenerator generator;
  late _RecordingRunner runner;
  final logs = <String>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('llm_runtime_test');
    api = await FakeApi.start();
    owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    stranger = await FakeUser.create('00000000-0000-4000-8000-00000000000e');
    api.keyBundles[owner.id] = await owner.keyBundle();
    api.keyBundles[stranger.id] = await stranger.keyBundle();
    api.handles['CT-AAAA-0001'] = owner.id;
    hub = FakeHub();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Pepa',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    provider = FakeProvider();
    generator = FakeGenerator();
    runner = _RecordingRunner();
    store = await HistoryStore.open(
      '${dir.path}/bot.store.llm',
      base64Decode(testStoreKey),
      cap: 20,
    );
    final allowed = await resolveAllowedHandles({
      'CT-AAAA-0001',
    }, bot.deviceIdForHandle);
    await runJayGlue(
      bot,
      bridge: LlmBridge(
        provider: provider,
        history: store,
        displayName: 'Pepa',
        systemPrompt: 's',
        progressAfter: Duration.zero,
        imageGenerator: generator,
        mediaDir: '${dir.path}/bot.store.media',
        actions: runner,
      ),
      allowedIds: allowed,
      // The existing tests count messages; ack_test.dart covers it on.
      ackReactions: false,
      log: logs.add,
    );
  });

  tearDown(() async {
    await bot.close();
    await owner.close();
    await stranger.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  test('publishes /new and /help as the bot menu', () {
    final published = api.botCommands[FakeApi.botId] as Map;
    expect(
      [for (final c in published['commands'] as List) c['command']],
      ['new', 'help'],
    );
  });

  test('owner message -> provider -> encrypted reply', () async {
    provider.scripts.add(() => answer(['Ahoj ', 'Martine']));
    hub.deliver(await owner.messageTo(bot.deviceId, api.botBundle, 'Ahoj'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(
      await owner.read(
        bot.deviceId,
        (sent[3] as Map<String, String>)[owner.id]!,
      ),
      'Ahoj Martine',
    );
    expect(provider.calls.single.conversation.single.text, 'Ahoj');
  });

  test('A7: the owner in 1:1 may trigger an action', () async {
    provider.scripts
      ..add(() => answer(['[action: status]']))
      ..add(() => answer(['Běží.']));
    hub.deliver(await owner.messageTo(bot.deviceId, api.botBundle, 'stav?'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
    await until(() => hub.calls('SendReliableDirectFanout').isNotEmpty);
    expect(runner.ran, ['status']);
    expect(provider.calls.first.system, contains('Actions:'));
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(
      await owner.read(
        bot.deviceId,
        (sent[3] as Map<String, String>)[owner.id]!,
      ),
      'Běží.',
    );
  });

  test(
    'non-owner is dropped before decrypt: no provider call, no reply',
    () async {
      hub.deliver(await stranger.messageTo(bot.deviceId, api.botBundle, 'hi'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      expect(provider.calls, isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    },
  );

  test('publishes the inbound policy: owners = the resolved handles', () {
    expect(api.botPolicies[FakeApi.botId], {
      'mode': 'owners',
      'owners': ['CT-AAAA-0001'],
    });
  });

  group('groups (bot-access A4)', () {
    const withOwner = '00000000-0000-4000-8000-0000000000c1';
    const withoutOwner = '00000000-0000-4000-8000-0000000000c2';
    late FakeUser other;

    setUp(() async {
      other = await FakeUser.create('00000000-0000-4000-8000-00000000000f');
      api.keyBundles[other.id] = await other.keyBundle();
      api.groups[withOwner] = [owner.id, stranger.id, bot.deviceId];
      api.groups[withoutOwner] = [stranger.id, other.id, bot.deviceId];
      api.memberFields[stranger.id] = {'userHandle': 'CT-MEMB-0002'};
    });
    tearDown(() => other.close());

    Future<void> say(FakeUser from, String group, String text) async {
      final before = hub.calls('AcknowledgeMessage').length;
      hub.deliver(
        await from.messageTo(
          bot.deviceId,
          api.botBundle,
          '@${bot.handle} $text',
          groupId: group,
        ),
      );
      await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
    }

    test('a member of a group with the owner is answered, labelled', () async {
      provider.scripts.add(() => answer(['Ahoj']));
      await say(stranger, withOwner, 'kolik je hodin?');
      expect(
        provider.calls.single.conversation.single.text,
        '[from CT-MEMB-0002] @${bot.handle} kolik je hodin?',
      );
      final sent = hub.calls('SendReliableGroupFanout').single;
      final payload = await stranger.readPayload(
        bot.deviceId,
        (sent[3] as Map<String, String>)[stranger.id]!,
      );
      expect(payload['body'], 'Ahoj');
      // The reply quotes the asker, like an answer to an owner.
      expect((payload['replyTo'] as Map)['senderId'], stranger.id);
    });

    test(
      'A7: in a group nobody triggers actions, not even the owner',
      () async {
        provider.scripts
          ..add(() => answer(['[action: status] ok']))
          ..add(() => answer(['[action: status] ok']));
        await say(stranger, withOwner, 'status?');
        await say(owner, withOwner, 'status?');
        expect(runner.ran, isEmpty);
        expect(provider.calls, hasLength(2));
        for (final c in provider.calls) {
          expect(c.system, isNot(contains('Actions:')));
        }
      },
    );

    test('the same member in a group without an owner gets nothing', () async {
      await say(stranger, withoutOwner, 'hello?');
      expect(provider.calls, isEmpty);
      expect(hub.calls('SendReliableGroupFanout'), isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
    });
  });

  test('greeting goes to each owner exactly once, across restarts', () async {
    Future<void> greet(HistoryStore s) => greetOwners(
      handles: ['CT-AAAA-0001'],
      store: s,
      send: (handle, text) => bot.send(to: handle, text: text),
      displayName: 'Pepa',
    );
    await greet(store);
    // A restart reopens the store from disk.
    await greet(
      await HistoryStore.open(
        '${dir.path}/bot.store.llm',
        base64Decode(testStoreKey),
        cap: 20,
      ),
    );
    final sends = hub.calls('SendReliableDirectFanout');
    expect(sends, hasLength(1));
    expect(
      await owner.read(
        bot.deviceId,
        (sends.single[3] as Map<String, String>)[owner.id]!,
      ),
      'Ahoj, jsem Pepa. Napiš mi.\nHi, I am Pepa. Write to me.',
    );
  });

  test('a failed greeting is not marked and is retried later', () async {
    final logs = <String>[];
    await greetOwners(
      handles: ['CT-AAAA-0001'],
      store: store,
      send: (_, _) async => throw StateError('offline'),
      displayName: 'Pepa',
      log: logs.add,
    );
    expect(await store.greeted('CT-AAAA-0001'), isFalse);
    expect(logs.single, contains('will retry'));
  });

  group('images (spec 2026-11-10-bot-media)', () {
    Future<void> send(
      FakeUser from,
      String text, {
      Map<String, dynamic> extra = const {},
      String? groupId,
    }) async {
      final before = hub.calls('AcknowledgeMessage').length;
      hub.deliver(
        await from.messageTo(
          bot.deviceId,
          api.botBundle,
          text,
          extra: extra,
          groupId: groupId,
        ),
      );
      await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
    }

    Future<Map<String, dynamic>> lastReplyTo(FakeUser user) async =>
        user.readPayload(
          bot.deviceId,
          (hub.calls('SendReliableDirectFanout').last[3]
              as Map<String, String>)[user.id]!,
        );

    test(
      'an owner image (media) reaches the provider with its caption',
      () async {
        provider.scripts.add(() => answer(['A cat.']));
        final media = await uploadMedia(
          api,
          pngBytes,
          kind: MediaKind.image,
          name: 'cat.png',
          mime: 'image/png',
          durationMs: null,
          caption: 'what is it?',
        );
        await send(
          owner,
          'Image (1 KB). Update Jay.\nwhat is it?',
          extra: {'media': media},
        );
        final turn = provider.calls.single.conversation.single;
        expect(turn.text, '[image: cat.png]\nwhat is it?');
        expect(turn.images.single.bytes, pngBytes);
        expect(turn.images.single.mediaType, 'image/png');
        expect((await lastReplyTo(owner))['body'], 'A cat.');
      },
    );

    test('an inline photo (type file) is read too', () async {
      provider.scripts.add(() => answer(['Nice.']));
      await send(
        owner,
        jsonEncode({'name': 'p.png', 'data': base64Encode(pngBytes)}),
        extra: {'type': 'file'},
      );
      final turn = provider.calls.single.conversation.single;
      expect(turn.text, '[image: p.png]');
      expect(turn.images.single.bytes, pngBytes);
    });

    test('a voice message gets a polite text, no provider call', () async {
      final media = await uploadMedia(api, Uint8List.fromList([1, 2, 3]));
      await send(owner, 'Voice message (0:10).', extra: {'media': media});
      expect(provider.calls, isEmpty);
      expect((await lastReplyTo(owner))['body'], contains('JPEG, PNG'));
      expect(api.requests.where((r) => r.startsWith('GET /media/')), isEmpty);
    });

    test("a stranger's image is never downloaded", () async {
      final media = await uploadMedia(
        api,
        pngBytes,
        kind: MediaKind.image,
        name: 'x.png',
        mime: 'image/png',
        durationMs: null,
      );
      await send(stranger, 'Image', extra: {'media': media});
      expect(provider.calls, isEmpty);
      expect(api.requests.where((r) => r.startsWith('GET /media/')), isEmpty);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    });

    test('a member image in a group without an owner is ignored', () async {
      const group = '00000000-0000-4000-8000-0000000000c3';
      final other = await FakeUser.create(
        '00000000-0000-4000-8000-00000000001f',
      );
      addTearDown(other.close);
      api.keyBundles[other.id] = await other.keyBundle();
      api.groups[group] = [stranger.id, other.id, bot.deviceId];
      final media = await uploadMedia(
        api,
        pngBytes,
        kind: MediaKind.image,
        name: 'x.png',
        mime: 'image/png',
        durationMs: null,
        caption: '@${bot.handle} look',
      );
      await send(
        stranger,
        'Image\n@${bot.handle} look',
        extra: {'media': media},
        groupId: group,
      );
      expect(provider.calls, isEmpty);
      expect(api.requests.where((r) => r.startsWith('GET /media/')), isEmpty);
    });

    test('a generated image is uploaded and sent as media', () async {
      provider.scripts.add(() => answer(['Here. [[image: a red square]]']));
      await send(owner, 'draw a red square');
      expect(generator.prompts, ['a red square']);
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      final payload = await lastReplyTo(owner);
      // Small images go inline like the app's photos.
      expect(payload['type'], 'file');
      final body = jsonDecode(payload['body'] as String) as Map;
      expect(base64Decode(body['data'] as String), pngBytes);
      expect(Directory('${dir.path}/bot.store.media').listSync(), isEmpty);
    });
  });
}

/// Records action names; runs nothing.
class _RecordingRunner extends ActionRunner {
  _RecordingRunner() : super(parseActions('status=fake-status'));

  final ran = <String>[];

  @override
  Future<ActionResult> run(String name) async {
    ran.add(name);
    return ActionResult(name: name, exitCode: 0, output: 'active');
  }
}
