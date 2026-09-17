import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('EncryptedFileStore', () {
    late Directory dir;
    late String path;
    final key = EncryptedFileStore.parseKey(testStoreKey);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bot_store_test');
      path = '${dir.path}/nested/bot.store';
    });
    tearDown(() => dir.delete(recursive: true));

    test('round-trips across re-open and keeps no plaintext on disk', () async {
      final store = await EncryptedFileStore.open(path, key);
      await store.write('ct_device_secret', 'super-secret-value');
      await store.write('gone', 'x');
      await store.delete('gone');

      final reopened = await EncryptedFileStore.open(path, key);
      expect(await reopened.read('ct_device_secret'), 'super-secret-value');
      expect(await reopened.read('gone'), isNull);
      expect(
        latin1.decode(await File(path).readAsBytes()),
        isNot(contains('super-secret-value')),
      );
    });

    test('wrong key refuses to open instead of starting empty', () async {
      await (await EncryptedFileStore.open(path, key)).write('k', 'v');
      final wrong = EncryptedFileStore.parseKey(base64Encode(List.filled(32, 1)));
      expect(EncryptedFileStore.open(path, wrong), throwsStateError);
    });

    test('writes are atomic: no temp file left, concurrent writes all land', () async {
      final store = await EncryptedFileStore.open(path, key);
      await Future.wait([
        for (var i = 0; i < 20; i++) store.write('k$i', 'v$i'),
      ]);
      expect(await File('$path.tmp').exists(), isFalse);
      final reopened = await EncryptedFileStore.open(path, key);
      expect(await reopened.read('k19'), 'v19');
      expect(await reopened.read('k0'), 'v0');
    });

    test('a leftover half-written temp file does not affect the store', () async {
      await (await EncryptedFileStore.open(path, key)).write('k', 'v');
      // Simulates a crash between "write temp" and "rename".
      await File('$path.tmp').writeAsString('truncated garbage');
      expect(await (await EncryptedFileStore.open(path, key)).read('k'), 'v');
    });

    test('missing, malformed or short BOT_STORE_KEY is rejected', () {
      expect(() => EncryptedFileStore.parseKey(null), throwsStateError);
      expect(() => EncryptedFileStore.parseKey(' '), throwsStateError);
      expect(() => EncryptedFileStore.parseKey('%%%'), throwsStateError);
      expect(
        () => EncryptedFileStore.parseKey(base64Encode(List.filled(16, 0))),
        throwsStateError,
      );
    });
  });

  group('mentionsBot', () {
    bool m(String text) =>
        mentionsBot(text, handle: 'CT-AB12-CD34', displayName: 'Hermes');

    test('matches handle or display name, case-insensitively', () {
      expect(m('hey @CT-AB12-CD34 what time is it'), isTrue);
      expect(m('@ct-ab12-cd34'), isTrue);
      expect(m('ok @hermes, go'), isTrue);
      expect(m('@HERMES?'), isTrue);
    });

    test('ignores plain text, other mentions and longer names', () {
      expect(m('hermes is a bot'), isFalse);
      expect(m('@alice hi'), isFalse);
      expect(m('@Hermeskeil is a town'), isFalse);
      expect(m('@CT-AB12-CD345'), isFalse);
    });
  });
}
