import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// `send()` (a bot starting a message) and `group()` (bot-talk settings and
/// members), over the same real-crypto fakes as the runtime tests.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late FakeUser bob;
  late CallTypeBot bot;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_send_test');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.keyBundles[bob.id] = await bob.keyBundle();
    api.handles['CT-AAAA-0001'] = alice.id;
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: (_) {},
      sendRetryDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await bob.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  group('send', () {
    // Sending needs the hub connection, which onMessage opens.
    setUp(() => bot.onMessage((_) async {}));

    test(
      'to a handle: direct fan-out the user can decrypt (no prior session)',
      () async {
        await bot.send(to: 'ct-aaaa-0001', text: 'build is green');
        final sent = hub.calls('SendReliableDirectFanout').single;
        expect(sent[0], alice.id);
        final copies = sent[3] as Map<String, String>;
        expect(copies.keys, [alice.id]);
        expect(
          await alice.read(bot.deviceId, copies[alice.id]!),
          'build is green',
        );
      },
    );

    test(
      "to a handle: every device of the user's signed list gets a copy",
      () async {
        final aliceWeb = await FakeUser.create(
          '00000000-0000-4000-8000-0000000000aa',
        );
        addTearDown(aliceWeb.close);
        api.keyBundles[aliceWeb.id] = await aliceWeb.keyBundle();
        final list = await signedDeviceList(alice, [aliceWeb], version: 1);
        api.deviceLists[alice.id] = list;
        api.deviceLists[aliceWeb.id] = list;

        await bot.send(to: 'CT-AAAA-0001', text: 'both');
        final copies =
            hub.calls('SendReliableDirectFanout').single[3]
                as Map<String, String>;
        expect(copies.keys.toSet(), {alice.id, aliceWeb.id});
        expect(await aliceWeb.read(bot.deviceId, copies[aliceWeb.id]!), 'both');
      },
    );

    test('to a group id: one group fan-out to every other member', () async {
      api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
      await bot.send(to: groupId, text: 'deploy 28f5070');
      final sent = hub.calls('SendReliableGroupFanout').single;
      expect(sent[0], groupId);
      final copies = sent[3] as Map<String, String>;
      expect(copies.keys.toSet(), {alice.id, bob.id});
      expect(await bob.read(bot.deviceId, copies[bob.id]!), 'deploy 28f5070');
    });

    test('unknown handle, foreign group and empty text are refused', () async {
      await expectLater(
        bot.send(to: 'CT-NOPE-0000', text: 'x'),
        throwsA(isA<BotSendException>()),
      );
      api.groups[groupId] = [alice.id, bob.id]; // bot not a member
      await expectLater(
        bot.send(to: groupId, text: 'x'),
        throwsA(isA<BotSendException>()),
      );
      await expectLater(
        bot.send(to: 'CT-AAAA-0001', text: '  '),
        throwsArgumentError,
      );
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      expect(hub.calls('SendReliableGroupFanout'), isEmpty);
    });
  });

  group('group()', () {
    test('settings + members with roles and bot flags', () async {
      api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
      api.groupDetails[groupId] = {
        'groupId': groupId,
        'botTalk': {
          'mode': 'selected',
          'allowedBotDeviceIds': [bob.id, bot.deviceId],
          'maxBotTurns': 4,
          'pauseMinutes': 15,
        },
      };
      api.memberFields[alice.id] = {
        'role': 'admin',
        'userHandle': 'CT-AAAA-0001',
      };
      api.memberFields[bob.id] = {'isBot': true};

      final info = await bot.group(groupId);
      expect(info.botTalk.mode, BotTalkMode.selected);
      expect(info.botTalk.maxBotTurns, 4);
      expect(info.member(alice.id)!.isAdmin, isTrue);
      expect(info.member(alice.id)!.handle, 'CT-AAAA-0001');
      expect(info.member(bob.id)!.isBot, isTrue);
      expect(info.isMember(bot.deviceId.toUpperCase()), isTrue);
    });

    test('old server without botTalk reads as off', () async {
      api.groups[groupId] = [alice.id, bot.deviceId];
      expect((await bot.group(groupId)).botTalk.mode, BotTalkMode.off);
    });

    test('cached until the GroupChanged hint, then re-read', () async {
      api.groups[groupId] = [alice.id, bot.deviceId];
      await bot.onMessage((_) async {});
      await bot.group(groupId);
      await bot.group(groupId);
      expect(
        api.requests.where((r) => r == 'GET /groups/$groupId'),
        hasLength(1),
      );

      api.groupDetails[groupId] = {
        'botTalk': {'mode': 'all'},
      };
      hub.push('GroupChanged', {'groupId': groupId});
      await pumpEventQueue(); // stream events arrive asynchronously
      expect((await bot.group(groupId)).botTalk.mode, BotTalkMode.all);
      expect(
        api.requests.where((r) => r == 'GET /groups/$groupId'),
        hasLength(2),
      );

      hub.push('DeviceListChanged', {
        'primaryDeviceId': alice.id,
        'version': 2,
      });
      await pumpEventQueue();
      await bot.group(groupId);
      expect(
        api.requests.where((r) => r == 'GET /groups/$groupId'),
        hasLength(3),
      );
    });

    test('a failed load is not cached', () async {
      await expectLater(
        bot.group(groupId),
        throwsA(anything),
      ); // unknown -> 404
      api.groups[groupId] = [bot.deviceId];
      expect((await bot.group(groupId)).isMember(bot.deviceId), isTrue);
    });
  });

  group('BotMessage', () {
    test('carries groupId and senderIsBot from the member list', () async {
      api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
      api.memberFields[bob.id] = {'isBot': true};
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));

      hub.deliver(
        await bob.messageTo(
          bot.deviceId,
          api.botBundle,
          '@hermes hi',
          groupId: groupId,
        ),
      );
      hub.deliver(
        await alice.messageTo(
          bot.deviceId,
          api.botBundle,
          '@hermes yo',
          groupId: groupId,
        ),
      );
      await until(() => seen.length == 2);
      expect(seen[0].groupId, groupId);
      expect(seen[0].senderIsBot, isTrue);
      expect(seen[1].senderIsBot, isFalse);
    });

    test('1:1: no groupId, senderIsBot unknown', () async {
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hi'));
      await until(() => seen.length == 1);
      expect(seen.single.groupId, isNull);
      expect(seen.single.senderIsBot, isNull);
    });

    test(
      'allowGroupSender admits a refused sender only for its group claim',
      () async {
        api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
        final asked = <(String, String)>[];
        final seen = <BotMessage>[];
        await bot.onMessage(
          (m) async => seen.add(m),
          allowSender: (_) => false,
          allowGroupSender: (sender, group) async {
            asked.add((sender, group));
            return sender == bob.id;
          },
        );
        hub.deliver(
          await bob.messageTo(
            bot.deviceId,
            api.botBundle,
            '@hermes a',
            groupId: groupId,
          ),
        );
        hub.deliver(
          await alice.messageTo(
            bot.deviceId,
            api.botBundle,
            '@hermes b',
            groupId: groupId,
          ),
        );
        hub.deliver(await bob.messageTo(bot.deviceId, api.botBundle, 'direct'));
        await until(() => hub.calls('AcknowledgeMessage').length == 3);
        expect(seen.map((m) => m.text), ['@hermes a']);
        // Never asked for the 1:1 message: no group claim, no second chance.
        expect(asked, [(bob.id, groupId), (alice.id, groupId)]);
      },
    );
  });
}
