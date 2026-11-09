import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Runtime tests with TWO real crypto stacks: a [FakeUser] built on the real
/// calltype_core SessionManager talks to the bot through a fake hub + a
/// loopback REST fake. No real server: the API needs PostgreSQL (Docker).
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  final bots = <CallTypeBot>[];
  final logs = <String>[];

  Future<CallTypeBot> startBot() async {
    hub = FakeHub();
    final bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    bots.add(bot);
    return bot;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_test');
    api = await FakeApi.start();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    api.keyBundles[alice.id] = await alice.keyBundle();
    logs.clear();
  });

  tearDown(() async {
    for (final bot in bots) {
      await bot.close();
    }
    bots.clear();
    await alice.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  test('first start registers as a bot and prints handle + invite', () async {
    final bot = await startBot();
    expect(api.registrations.single['isBot'], isTrue);
    expect(bot.handle, FakeApi.botHandle);
    expect(logs.join('\n'), contains(FakeApi.botHandle));
    expect(logs.join('\n'), contains('ct://${FakeApi.botId}/'));
  });

  test('pre-key message -> handler -> encrypted reply, typing, ack last', () async {
    final bot = await startBot();
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async {
      seen.add(msg);
      // Ack must not have happened while the handler is still running.
      expect(hub.calls('AcknowledgeMessage'), isEmpty);
      await msg.reply('echo: ${msg.text}');
    });

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hi'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(seen.single.text, 'hi');
    expect(seen.single.isGroup, isFalse);
    expect(seen.single.conversationId, alice.id);
    expect(hub.calls('TypingIndicator').first, [alice.id]);
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(sent[0], alice.id);
    expect(await alice.read(bot.deviceId, (sent[3] as Map<String, String>)[alice.id]!), 'echo: hi');
    expect(hub.calls('AcknowledgeMessage').single, [alice.id, seen.single.id]);
  });

  test('replayed message never reaches the handler twice, even after restart', () async {
    var bot = await startBot();
    var handled = 0;
    await bot.onMessage((msg) async => handled++);

    final delivery = await alice.messageTo(bot.deviceId, api.botBundle, 'once');
    hub.deliver(delivery);
    hub.deliver(delivery);
    await until(() => hub.calls('AcknowledgeMessage').length == 2);
    expect(handled, 1);

    // Restart on the same store: same identity, no second registration.
    await bot.close();
    bots.clear();
    bot = await startBot();
    expect(api.registrations, hasLength(1));
    await bot.onMessage((msg) async {
      handled++;
      await msg.reply('still me');
    });

    hub.deliver(delivery);
    await until(() => hub.calls('AcknowledgeMessage').length == 1);
    expect(handled, 1, reason: 'replay after restart must only be acked');

    // The session survived the restart: a follow-up decrypts and the reply
    // is readable by the user (no identity / safety-number change).
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'again'));
    await until(() => hub.calls('SendReliableDirectFanout').isNotEmpty);
    expect(handled, 2);
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(await alice.read(bot.deviceId, (sent[3] as Map<String, String>)[alice.id]!), 'still me');
  });

  test('handler exception -> apology reply, ack, loop survives', () async {
    final bot = await startBot();
    await bot.onMessage((msg) async {
      if (msg.text == 'boom') throw StateError('backend down');
      await msg.reply('ok');
    });

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'boom'));
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'fine'));
    await until(() => hub.calls('AcknowledgeMessage').length == 2);

    final replies = [
      for (final sent in hub.calls('SendReliableDirectFanout'))
        await alice.read(bot.deviceId, (sent[3] as Map<String, String>)[alice.id]!),
    ];
    expect(replies, [startsWith('Sorry'), 'ok']);
    expect(logs.join('\n'), contains('backend down'));
  });

  test('handlers are serial per conversation, parallel across them', () async {
    final bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    addTearDown(bob.close);
    final bot = await startBot();
    final started = <String>[];
    final gate = Completer<void>();
    addTearDown(() => gate.isCompleted ? null : gate.complete());
    await bot.onMessage((msg) async {
      started.add(msg.text);
      if (msg.text == 'a1') await gate.future;
    });

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'a1'));
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'a2'));
    hub.deliver(await bob.messageTo(bot.deviceId, api.botBundle, 'b1'));
    await until(() => started.contains('b1'));
    // Bob was served while Alice's first handler is still blocked …
    expect(started, ['a1', 'b1']);
    gate.complete();
    // … and Alice's second message starts only after her first finished.
    await until(() => started.length == 3);
    expect(started.last, 'a2');
  });

  test('group: silent without a mention, replies to every member with one', () async {
    const groupId = '00000000-0000-4000-8000-0000000000c0';
    final bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    addTearDown(bob.close);
    api.keyBundles[bob.id] = await bob.keyBundle();
    final bot = await startBot();
    api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async {
      seen.add(msg);
      await msg.reply('pong');
    });

    hub.deliver(
      await alice.messageTo(bot.deviceId, api.botBundle, 'hello all', groupId: groupId),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == 1);
    expect(seen, isEmpty);
    expect(hub.calls('TypingIndicator'), isEmpty);

    hub.deliver(
      await alice.messageTo(bot.deviceId, api.botBundle, '@hermes ping', groupId: groupId),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == 2);
    expect(seen.single.isGroup, isTrue);
    expect(seen.single.mentionsBot, isTrue);
    expect(seen.single.conversationId, groupId);

    final sends = hub.calls('SendReliableGroupFanout');
    // ONE call for the whole group: a business group's hub rejects any call
    // that lacks the auditor's envelope (KB2), so per-recipient calls would
    // make the bot mute there.
    expect(sends, hasLength(1));
    final recipients = {
      for (final s in sends) ...(s[3] as Map<String, String>).keys,
    };
    expect(recipients, {alice.id, bob.id});
    // Bob never talked to the bot: his copy is a pre-key message that his
    // real stack can establish a session from.
    final bobCopy = sends
        .map((s) => s[3] as Map<String, String>)
        .firstWhere((m) => m.containsKey(bob.id))[bob.id]!;
    expect(await bob.read(bot.deviceId, bobCopy), 'pong');
  });

  test('disallowed sender: acked and dropped, no typing, no handler', () async {
    final bot = await startBot();
    var handled = 0;
    await bot.onMessage((msg) async => handled++, allowSender: (id) => false);

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'rm -rf /'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(handled, 0);
    expect(hub.calls('TypingIndicator'), isEmpty);
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });

  test('undecryptable message is not acked and does not stop the loop', () async {
    final bot = await startBot();
    var handled = 0;
    await bot.onMessage((msg) async => handled++);

    hub.deliver({
      'senderId': alice.id,
      'messageId': 'garbage',
      'groupId': null,
      'encryptedBody': 'bm90IGpzb24=',
    });
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'real'));
    await until(() => handled == 1);
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(hub.calls('AcknowledgeMessage').map((a) => a[1]), isNot(contains('garbage')));
  });

  test('crash between ratchet step and seen-row insert: no advance, no duplicate', () async {
    // The bot wraps decryptMessage and its seen-row insert in ONE drift
    // transaction, and SessionManager's own transaction (through
    // DriftProtocolStore) joins it. A failing insert must therefore roll back
    // the ratchet step too: the message stays unacked and is handled exactly
    // once when it is delivered again.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final bot = await startBot();
    final handled = <String>[];
    await bot.onMessage((msg) async => handled.add(msg.text));
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'setup'));
    await until(() => hub.calls('AcknowledgeMessage').length == 1);

    // A second connection to the bot's database injects the crash.
    final side = AppDatabase(NativeDatabase(File('${dir.path}/bot.store.sqlite')));
    addTearDown(side.close);
    Future<List<String>> sessions() async => [
      for (final r in await (side.select(side.signalSessions)
            ..orderBy([(s) => OrderingTerm.asc(s.address)]))
          .get())
        '${r.address}=${base64Encode(r.sessionData)}',
    ];
    final before = await sessions();
    await side.customStatement(
      "CREATE TRIGGER crash_seen BEFORE INSERT ON messages "
      "BEGIN SELECT RAISE(ABORT, 'simulated crash'); END",
    );

    final delivery = await alice.messageTo(bot.deviceId, api.botBundle, 'crash');
    hub.deliver(delivery);
    await until(() => logs.any((l) => l.contains('simulated crash')));
    expect(await sessions(), before, reason: 'the ratchet must not advance');
    expect(hub.calls('AcknowledgeMessage'), hasLength(1));
    expect(handled, ['setup']);

    await side.customStatement('DROP TRIGGER crash_seen');
    hub.deliver(delivery);
    await until(() => hub.calls('AcknowledgeMessage').length == 2);
    hub.deliver(delivery);
    await until(() => hub.calls('AcknowledgeMessage').length == 3);
    expect(handled, ['setup', 'crash']);
  });

  test('deviceIdForHandle resolves known handles, null otherwise', () async {
    final bot = await startBot();
    api.handles['CT-AAAA-0001'] = alice.id;
    expect(await bot.deviceIdForHandle('CT-AAAA-0001'), alice.id);
    expect(await bot.deviceIdForHandle('CT-NOPE-0000'), isNull);
  });

  test("a user's companion lands in the user's conversation; the reply reaches both devices", () async {
    final aliceWeb = await FakeUser.create('00000000-0000-4000-8000-0000000000aa');
    addTearDown(aliceWeb.close);
    api.keyBundles[aliceWeb.id] = await aliceWeb.keyBundle();
    final list = await signedDeviceList(alice, [aliceWeb], version: 1);
    api.deviceLists[alice.id] = list;
    api.deviceLists[aliceWeb.id] = list;
    final bot = await startBot();
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async {
      seen.add(msg);
      await msg.reply('hi both');
    });

    hub.deliver(await aliceWeb.messageTo(bot.deviceId, api.botBundle, 'from the web'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(seen.single.senderId, alice.id);
    expect(seen.single.conversationId, alice.id);
    // Acknowledged with the TRANSPORT sender: the server queues per device.
    expect(hub.calls('AcknowledgeMessage').single, [aliceWeb.id, seen.single.id]);
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(sent[0], alice.id);
    final payloads = sent[3] as Map<String, String>;
    expect(payloads.keys.toSet(), {alice.id, aliceWeb.id});
    expect(await aliceWeb.read(bot.deviceId, payloads[aliceWeb.id]!), 'hi both');
    expect(await alice.read(bot.deviceId, payloads[alice.id]!), 'hi both');
  });

  test('a server hint naming another identity re-reads the list: a removed companion is no longer the user', () async {
    final aliceWeb = await FakeUser.create('00000000-0000-4000-8000-0000000000aa');
    addTearDown(aliceWeb.close);
    api.keyBundles[aliceWeb.id] = await aliceWeb.keyBundle();
    final list = await signedDeviceList(alice, [aliceWeb], version: 1);
    api.deviceLists[alice.id] = list;
    api.deviceLists[aliceWeb.id] = list;
    final bot = await startBot();
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async => seen.add(msg));
    hub.deliver(await aliceWeb.messageTo(bot.deviceId, api.botBundle, 'while listed'));
    await until(() => seen.length == 1);
    expect(seen.single.senderId, alice.id);

    // Alice removes the web device; the bot has not heard yet.
    final v2 = await signedDeviceList(alice, [], version: 2);
    api.deviceLists[alice.id] = v2;
    api.deviceLists[aliceWeb.id] = v2;
    final event = await aliceWeb.messageTo(bot.deviceId, api.botBundle, 'after removal');
    hub.deliver({...event, 'senderPrimaryId': aliceWeb.id});
    await until(() => seen.length == 2);

    expect(seen.last.senderId, aliceWeb.id);
    expect(seen.last.conversationId, aliceWeb.id);
  });

  test('a companion the bot does not know yet: device_list_stale repairs the fan-out', () async {
    final aliceWeb = await FakeUser.create('00000000-0000-4000-8000-0000000000aa');
    addTearDown(aliceWeb.close);
    api.keyBundles[aliceWeb.id] = await aliceWeb.keyBundle();
    final list = await signedDeviceList(alice, [aliceWeb], version: 1);
    final bot = await startBot();
    await bot.onMessage((msg) => msg.reply('hello'));
    // Alice's own id has no list yet (the bot sees her as a single device);
    // by the time the hub complains, the list is published for the companion.
    hub.failures['SendReliableDirectFanout'] = [
      () {
        api.deviceLists[aliceWeb.id] = list;
        return Exception('device_list_stale:${alice.id},${aliceWeb.id}');
      },
    ];

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hi'));
    await until(() => hub.calls('SendReliableDirectFanout').length == 2);

    final calls = hub.calls('SendReliableDirectFanout');
    final first = calls.first[3] as Map<String, String>;
    final second = calls.last[3] as Map<String, String>;
    expect(first.keys.toSet(), {alice.id});
    expect(second.keys.toSet(), {alice.id, aliceWeb.id});
    // The kept envelope is byte for byte the first one (no ratchet step).
    expect(second[alice.id], first[alice.id]);
    expect(calls.last[1], calls.first[1]);
    expect(await aliceWeb.read(bot.deviceId, second[aliceWeb.id]!), 'hello');
  });

  test('business group: falls back to the per-member call with the same message id', () async {
    const groupId = '00000000-0000-4000-8000-0000000000c1';
    final bot = await startBot();
    api.groups[groupId] = [alice.id, bot.deviceId];
    await bot.onMessage((msg) => msg.reply('pong'));
    hub.failures['SendReliableGroupFanout'] = [
      () => Exception('fanout_unsupported_in_business_group'),
    ];

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, '@hermes ping', groupId: groupId));
    await until(() => hub.calls('SendReliableGroupMessage').isNotEmpty);

    final refused = hub.calls('SendReliableGroupFanout').single;
    final fallback = hub.calls('SendReliableGroupMessage').single;
    final payloads = fallback[2] as Map<String, String>;
    expect(fallback[0], groupId);
    expect(fallback[1], refused[1]);
    expect(payloads.keys.toSet(), {alice.id});
    expect(await alice.read(bot.deviceId, payloads[alice.id]!), 'pong');
  });

  test('group: a member added before the send is picked up after device_list_stale', () async {
    const groupId = '00000000-0000-4000-8000-0000000000c2';
    final bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    addTearDown(bob.close);
    api.keyBundles[bob.id] = await bob.keyBundle();
    final bot = await startBot();
    api.groups[groupId] = [alice.id, bot.deviceId];
    await bot.onMessage((msg) => msg.reply('pong'));
    // Bob joins between the bot's first member read and the hub's answer.
    hub.failures['SendReliableGroupFanout'] = [
      () {
        api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
        return Exception('device_list_stale:${alice.id},${bob.id}');
      },
    ];

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, '@hermes ping', groupId: groupId));
    await until(() => hub.calls('SendReliableGroupFanout').length == 2);

    final second = hub.calls('SendReliableGroupFanout').last[3] as Map<String, String>;
    expect(second.keys.toSet(), {alice.id, bob.id});
    expect(await bob.read(bot.deviceId, second[bob.id]!), 'pong');
  });

  group("copies from the bot's own devices", () {
    // The bot is a primary with one extra device; the list is signed with the
    // bot's REAL signing key, read from its store the way the bot reads it.
    late FakeUser twin;
    late bool handled;

    Future<CallTypeBot> startWithTwin() async {
      twin = await FakeUser.create('00000000-0000-4000-8000-0000000000b1');
      addTearDown(twin.close);
      final bot = await startBot();
      handled = false;
      await bot.onMessage((msg) async => handled = true);
      final store = await EncryptedFileStore.open(
        '${dir.path}/bot.store',
        EncryptedFileStore.parseKey(testStoreKey),
      );
      final botKeys = KeyManager(secureStorage: store);
      final signed = await signDeviceList(
        primarySigningKey: await botKeys.getSigningKeyPair(),
        list: DeviceList(
          primaryDeviceId: bot.deviceId,
          version: 1,
          devices: [
            DeviceListEntry(
              deviceId: twin.id,
              identityKey: await twin.keys.getPublicIdentityKey(),
              signingKey: (await twin.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await twin.keys.getSigningKeyPair(),
                primaryDeviceId: bot.deviceId,
                companionDeviceId: twin.id,
              ),
            ),
          ],
        ),
      );
      api.deviceLists[twin.id] = {
        'primaryDeviceId': bot.deviceId,
        'version': 1,
        'payload': signed.payload,
        'signature': signed.signature,
      };
      return bot;
    }

    test('with `to` it is acknowledged and never answered', () async {
      final bot = await startWithTwin();
      hub.deliver(await twin.messageTo(bot.deviceId, api.botBundle, 'note to self', to: alice.id));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      expect(hub.calls('AcknowledgeMessage').single[0], twin.id);
      expect(handled, isFalse);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      expect(logs.where((l) => l.contains('Cannot decrypt')), isEmpty);
    });

    test('without `to` it is dropped and acknowledged (like the app inbox)', () async {
      final bot = await startWithTwin();
      hub.deliver(await twin.messageTo(bot.deviceId, api.botBundle, 'no target'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      expect(handled, isFalse);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    });
  });

  group('bot access (spec 2026-11-09-bot-access)', () {
    test('setInboundPolicy publishes owners, or open without owners', () async {
      final bot = await startBot();
      await bot.setInboundPolicy(ownersOnly: true, owners: {'CT-AAAA-0001'});
      expect(api.botPolicies[FakeApi.botId], {
        'mode': 'owners',
        'owners': ['CT-AAAA-0001'],
      });
      await bot.setInboundPolicy(ownersOnly: false, owners: {'CT-AAAA-0001'});
      expect(api.botPolicies[FakeApi.botId], {'mode': 'open', 'owners': []});
      api.policySupported = false;
      await expectLater(
        bot.setInboundPolicy(ownersOnly: true),
        throwsA(predicate(CallTypeBot.isNotFound)),
      );
    });

    test('publishInboundPolicy: owners by default, open on request, an old '
        'server or a bad value never stops the bot', () async {
      final bot = await startBot();
      await publishInboundPolicy(bot, owners: ['CT-AAAA-0001'], log: logs.add);
      expect(api.botPolicies[FakeApi.botId]?['mode'], 'owners');
      await publishInboundPolicy(bot,
          owners: ['CT-AAAA-0001'], inbound: 'OPEN', log: logs.add);
      expect(api.botPolicies[FakeApi.botId]?['mode'], 'open');
      await publishInboundPolicy(bot,
          owners: ['CT-AAAA-0001'], inbound: 'everyone', log: logs.add);
      expect(api.botPolicies[FakeApi.botId]?['mode'], 'owners');
      expect(logs.join('\n'), contains('is unknown'));
      api.policySupported = false;
      await publishInboundPolicy(bot, owners: ['CT-AAAA-0001'], log: logs.add);
      expect(logs.last, contains('no bot inbound policy yet'));
    });

    test('replenishPreKeys tops a low pool up to the target with fresh key ids, '
        'and the new keys open sessions', () async {
      final bot = await startBot();
      api.preKeyCount = 5;
      expect(await bot.replenishPreKeys(), CallTypeBot.preKeyTarget - 5);
      expect(api.uploadedPreKeys, hasLength(CallTypeBot.preKeyTarget - 5));
      expect(api.uploadedPreKeys.first['keyId'], 101);
      expect(api.uploadedPreKeys.first.keys, unorderedEquals(['keyId', 'publicKey']));
      // Full enough now: nothing more.
      expect(await bot.replenishPreKeys(), 0);

      // A peer that got one of the NEW keys can open a session.
      final bundle = Map<String, dynamic>.of(api.botBundle)
        ..['oneTimePreKey'] = api.uploadedPreKeys.last;
      String? got;
      await bot.onMessage((m) async => got = m.text);
      hub.deliver(await alice.messageTo(bot.deviceId, bundle, 'with a new key'));
      await until(() => got != null);
      expect(got, 'with a new key');
    });

    test('an old server without the endpoints is asked once, then never', () async {
      final bot = await startBot();
      expect(await bot.replenishPreKeys(), isNull);
      expect(await bot.replenishPreKeys(), isNull);
      expect(
        api.requests.where((r) => r.contains('one-time-prekeys')),
        hasLength(1),
      );
      expect(logs.join('\n'), contains('not replenishing'));
    });
  });
}

