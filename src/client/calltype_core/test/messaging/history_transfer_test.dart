import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/messaging/history_transfer.dart';
import 'package:test/test.dart';

const _target = 'a0000000-0000-4000-8000-000000000002';
const _media = '11111111-2222-4333-8444-555555555555';

Uint8List _bytes(int n, [int seed = 1]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + seed) % 256]);

void main() {
  group('QR code', () {
    test('round-trips and has the documented shape', () async {
      final pair = await newHistoryTransferKeyPair();
      final code = HistoryTransferCode(
        targetDeviceId: _target,
        transferId: newHistoryTransferId(),
        targetPublicKey: await historyTransferPublicKey(pair),
      );
      final raw = code.encode();
      expect(raw, startsWith('calltype://history-transfer?v=1&d=$_target&t='));
      expect(raw, isNot(contains('=&')));
      final parsed = HistoryTransferCode.parse('  $raw\n')!;
      expect(parsed.targetDeviceId, _target);
      expect(parsed.transferId, code.transferId);
      expect(parsed.targetPublicKey, code.targetPublicKey);
    });

    test('transfer ids are 128 bit hex and differ', () {
      final a = newHistoryTransferId();
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(newHistoryTransferId(), isNot(a));
    });

    test('anything else is refused', () {
      final key = base64Url.encode(_bytes(32)).replaceAll('=', '');
      final id = 'ab' * 16;
      for (final raw in [
        '',
        'calltype://contact/CT-AAAA-BBBB',
        'jaylink://x',
        'calltype://history-transfer?v=2&d=$_target&t=$id&k=$key',
        'calltype://history-transfer?v=1&d=nope&t=$id&k=$key',
        'calltype://history-transfer?v=1&d=$_target&t=short&k=$key',
        'calltype://history-transfer?v=1&d=$_target&t=$id&k=AAAA',
        'calltype://history-transfer?v=1&d=$_target&t=$id',
      ]) {
        expect(HistoryTransferCode.parse(raw), isNull, reason: raw);
      }
      expect(
        HistoryTransferCode.parse(
          'calltype://history-transfer?v=1&d=$_target&t=$id&k=$key',
        ),
        isNotNull,
      );
    });
  });

  group('key wrap', () {
    test('only the target key pair unwraps it', () async {
      final target = await newHistoryTransferKeyPair();
      final source = await newHistoryTransferKeyPair();
      final other = await newHistoryTransferKeyPair();
      final key = _bytes(32);
      final nonce = _bytes(7, 3);
      final wrapped = await wrapArchiveKey(
        source: source,
        targetPublicKey: await historyTransferPublicKey(target),
        key: key,
        nonce: nonce,
      );
      expect(wrapped, hasLength(12 + 39 + 16));
      final sourcePublic = await historyTransferPublicKey(source);
      final unwrapped = (await unwrapArchiveKey(
        target: target,
        sourcePublicKey: sourcePublic,
        wrapped: wrapped,
      ))!;
      expect(unwrapped.key, key);
      expect(unwrapped.nonce, nonce);

      // Wrong ephemeral key (a QR code that was not this device's).
      expect(
        await unwrapArchiveKey(
          target: other,
          sourcePublicKey: sourcePublic,
          wrapped: wrapped,
        ),
        isNull,
      );
      // Tampered bytes.
      final tampered = Uint8List.fromList(wrapped)..[20] ^= 1;
      expect(
        await unwrapArchiveKey(
          target: target,
          sourcePublicKey: sourcePublic,
          wrapped: tampered,
        ),
        isNull,
      );
      expect(
        await unwrapArchiveKey(
          target: target,
          sourcePublicKey: sourcePublic,
          wrapped: wrapped.sublist(1),
        ),
        isNull,
      );
    });

    test('a key of the wrong length is a bug at the sender', () async {
      final pair = await newHistoryTransferKeyPair();
      expect(
        () async => wrapArchiveKey(
          source: pair,
          targetPublicKey: await historyTransferPublicKey(pair),
          key: _bytes(16),
          nonce: _bytes(7),
        ),
        throwsArgumentError,
      );
    });
  });

  group('history-transfer body', () {
    HistoryTransferOffer offer() => HistoryTransferOffer(
      transferId: 'cd' * 16,
      targetDeviceId: _target,
      mediaId: _media,
      size: 1234,
      sha256: _bytes(32),
      sourceEphemeralKey: _bytes(32, 5),
      wrappedKey: _bytes(67, 9),
    );

    test('round-trips with the documented keys', () {
      final body = offer().encode();
      expect((jsonDecode(body) as Map).keys.toSet(), {
        'transferId',
        'targetDeviceId',
        'mediaId',
        'size',
        'sha256',
        'sourceEphemeralKey',
        'wrappedKey',
      });
      final decoded = HistoryTransferOffer.decode(body)!;
      expect(decoded.transferId, 'cd' * 16);
      expect(decoded.mediaId, _media);
      expect(decoded.size, 1234);
      expect(decoded.sha256, _bytes(32));
      expect(decoded.wrappedKey, _bytes(67, 9));
    });

    test('invalid bodies are refused', () {
      final good = jsonDecode(offer().encode()) as Map<String, dynamic>;
      for (final change in <Map<String, Object?>>[
        {'transferId': 'x'},
        {'targetDeviceId': 'x'},
        {'mediaId': 'x'},
        {'size': 0},
        {'size': '1'},
        {'sha256': base64Encode(_bytes(31))},
        {'sourceEphemeralKey': 'not base64!'},
        {'wrappedKey': base64Encode(_bytes(10))},
      ]) {
        expect(
          HistoryTransferOffer.decode(jsonEncode({...good, ...change})),
          isNull,
          reason: '$change',
        );
      }
      expect(HistoryTransferOffer.decode('nope'), isNull);
      expect(HistoryTransferOffer.decode(null), isNull);
    });

    test('done round-trips; invalid is refused', () {
      final done = HistoryTransferDone.decode(
        HistoryTransferDone('ef' * 16).encode(),
      )!;
      expect(done.transferId, 'ef' * 16);
      expect(HistoryTransferDone.decode('{"transferId":"x"}'), isNull);
      expect(HistoryTransferDone.decode('{}'), isNull);
    });
  });
}
