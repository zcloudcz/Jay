import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The bridge helpers of spec 2026-11-13-group-topics T2/T3.
void main() {
  group('GroupContextBuffer', () {
    test('formats, folds newlines and clears on take', () {
      final b = GroupContextBuffer();
      expect(b.take('G'), isNull);
      b.add('G', 'Alice', 'hi\n  all');
      b.add('g', 'Bot (bot)', 'beep');
      b.add('G', 'Bob', '   ');
      expect(
        b.take('G'),
        '[Meanwhile in the group:\n- Alice: hi / all\n- Bot (bot): beep]',
      );
      expect(b.take('G'), isNull);
    });

    test('keeps the newest entries within both limits', () {
      final b = GroupContextBuffer(maxEntries: 3, maxChars: 40);
      for (var i = 0; i < 5; i++) {
        b.add('G', 'u', 'm$i');
      }
      expect(b.peek('G'), ['- u: m2', '- u: m3', '- u: m4']);
      b.add('G', 'u', 'x' * 30); // 36 characters: only it fits
      expect(b.peek('G'), ['- u: ${'x' * 30}']);
      b.add('G', 'u', 'y' * 100); // longer than the cap alone: cut
      expect(b.peek('G').single.length, 40);
    });

    test('default limits are 50 entries / 8000 characters', () {
      final b = GroupContextBuffer();
      for (var i = 0; i < 60; i++) {
        b.add('G', 'u', '$i');
      }
      expect(b.peek('G'), hasLength(50));
      expect(b.peek('G').first, '- u: 10');
      for (var i = 0; i < 10; i++) {
        b.add('G', 'u', 'z' * 1000);
      }
      expect(b.peek('G').join('\n').length, lessThanOrEqualTo(8000));
    });
  });

  group('GroupTopicAnnouncer', () {
    late Map<String, int> saved;
    GroupTopicAnnouncer announcer() => GroupTopicAnnouncer(
      load: (c) async => saved[c],
      save: (c, v) async => saved[c] = v,
    );
    setUp(() => saved = {});

    test('first turn of a run and on change only', () async {
      var a = announcer();
      expect(await a.take('G', version: null), isNull);
      expect(await a.take('G', version: 5, topic: 'Brno'), 'Brno');
      expect(await a.take('g', version: 5, topic: 'Brno'), isNull);
      expect(await a.take('G', version: 6, topic: 'Prague'), 'Prague');
      expect(saved, {'g': 6});
      // A restart: the first turn tells it once more, then quiet again.
      a = announcer();
      expect(await a.take('G', version: 6, topic: 'Prague'), 'Prague');
      expect(await a.take('G', version: 6, topic: 'Prague'), isNull);
    });

    test('a cleared topic is said once, never when nothing was said', () async {
      var a = announcer();
      expect(await a.take('G', version: 3, topic: null), isNull);
      expect(saved, isEmpty);
      expect(await a.take('G', version: 4, topic: 'x'), 'x');
      expect(await a.take('G', version: 5, topic: ''), '');
      expect(GroupTopicAnnouncer.block(''), contains('cleared'));
      a = announcer();
      expect(await a.take('G', version: 5, topic: ''), isNull);
    });
  });

  test('bridge state survives a restart', () async {
    final dir = await Directory.systemTemp.createTemp('calltype_bot_state');
    final api = await FakeApi.start();
    Future<CallTypeBot> start() => CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      transportFactory: (_, _) => FakeHub(),
      log: (_) {},
    );
    var bot = await start();
    expect(await bot.readBridgeState('k'), isNull);
    await bot.writeBridgeState('k', '1');
    await bot.writeBridgeState('k', '2');
    await bot.close();
    bot = await start();
    expect(await bot.readBridgeState('k'), '2');
    await bot.close();
    await api.close();
    await dir.delete(recursive: true);
  });
}
