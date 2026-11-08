/// History transfer between the devices of ONE identity
/// (`type: history-transfer` and `history-transfer-done`): the QR code of
/// the receiving device, the key-delivery body and the archive key wrap
/// (docs/superpowers/specs/2026-11-08-contact-sync.md).
///
/// The archive itself is the app's backup JSON, gzip-compressed and sent
/// through the encrypted media relay. This file only carries what both
/// sides must agree on byte for byte.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Message payload `type` of the key delivery (source -> own devices).
const historyTransferType = 'history-transfer';

/// Message payload `type` the target sends after a successful import.
const historyTransferDoneType = 'history-transfer-done';

/// HKDF `info` of the archive key wrap.
const historyTransferInfo = 'CallType-HistoryTransfer-v1';

/// How long the target keeps its ephemeral key (and shows the QR code).
const historyTransferCodeLifetime = Duration(minutes: 15);

final _transferId = RegExp(r'^[0-9a-f]{32}$');
final _guid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// A random 128 bit transfer id, as 32 lowercase hex characters.
String newHistoryTransferId([Random? random]) {
  final rng = random ?? Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _unb64url(String value) {
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}

Uint8List? _unb64(Object? value) {
  if (value is! String) return null;
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

/// What the target shows as QR code and as copyable text:
/// `calltype://history-transfer?v=1&d=<deviceId>&t=<transferId>&k=<key>`.
class HistoryTransferCode {
  const HistoryTransferCode({
    required this.targetDeviceId,
    required this.transferId,
    required this.targetPublicKey,
  });

  final String targetDeviceId;
  final String transferId;

  /// The target's ephemeral X25519 public key (32 bytes).
  final Uint8List targetPublicKey;

  String encode() => Uri(
    scheme: 'calltype',
    host: 'history-transfer',
    queryParameters: {
      'v': '1',
      'd': targetDeviceId,
      't': transferId,
      'k': _b64url(targetPublicKey),
    },
  ).toString();

  /// Null for anything that is not a valid v1 code (also when pasted with
  /// surrounding whitespace removed by the caller or not).
  static HistoryTransferCode? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'calltype' ||
        uri.host != 'history-transfer' ||
        uri.queryParameters['v'] != '1') {
      return null;
    }
    final device = uri.queryParameters['d'];
    final transfer = uri.queryParameters['t'];
    final key = uri.queryParameters['k'];
    if (device == null ||
        !_guid.hasMatch(device) ||
        transfer == null ||
        !_transferId.hasMatch(transfer) ||
        key == null) {
      return null;
    }
    final publicKey = _unb64url(key);
    if (publicKey == null || publicKey.length != 32) return null;
    return HistoryTransferCode(
      targetDeviceId: device,
      transferId: transfer,
      targetPublicKey: publicKey,
    );
  }
}

/// The body of `history-transfer`: where the archive is and its key,
/// wrapped for the target's ephemeral key.
class HistoryTransferOffer {
  const HistoryTransferOffer({
    required this.transferId,
    required this.targetDeviceId,
    required this.mediaId,
    required this.size,
    required this.sha256,
    required this.sourceEphemeralKey,
    required this.wrappedKey,
  });

  final String transferId;
  final String targetDeviceId;

  /// The media relay id of the encrypted archive.
  final String mediaId;

  /// Plaintext (gzip) bytes of the archive.
  final int size;

  /// SHA-256 of the plaintext (gzip) archive.
  final Uint8List sha256;

  /// The source's ephemeral X25519 public key (32 bytes).
  final Uint8List sourceEphemeralKey;

  /// 12 byte nonce, ciphertext and 16 byte tag of the archive key and nonce.
  final Uint8List wrappedKey;

  String encode() => jsonEncode({
    'transferId': transferId,
    'targetDeviceId': targetDeviceId,
    'mediaId': mediaId,
    'size': size,
    'sha256': base64Encode(sha256),
    'sourceEphemeralKey': base64Encode(sourceEphemeralKey),
    'wrappedKey': base64Encode(wrappedKey),
  });

  static HistoryTransferOffer? decode(Object? body) {
    final json = _decodeMap(body);
    if (json == null) return null;
    final transferId = json['transferId'];
    final target = json['targetDeviceId'];
    final mediaId = json['mediaId'];
    final size = json['size'];
    final sha = _unb64(json['sha256']);
    final source = _unb64(json['sourceEphemeralKey']);
    final wrapped = _unb64(json['wrappedKey']);
    if (transferId is! String ||
        !_transferId.hasMatch(transferId) ||
        target is! String ||
        !_guid.hasMatch(target) ||
        mediaId is! String ||
        !_guid.hasMatch(mediaId) ||
        size is! int ||
        size <= 0 ||
        sha == null ||
        sha.length != 32 ||
        source == null ||
        source.length != 32 ||
        wrapped == null ||
        wrapped.length != 12 + _wrappedPlainLength + 16) {
      return null;
    }
    return HistoryTransferOffer(
      transferId: transferId,
      targetDeviceId: target,
      mediaId: mediaId,
      size: size,
      sha256: sha,
      sourceEphemeralKey: source,
      wrappedKey: wrapped,
    );
  }
}

/// The body of `history-transfer-done`.
class HistoryTransferDone {
  const HistoryTransferDone(this.transferId);
  final String transferId;

  String encode() => jsonEncode({'transferId': transferId});

  static HistoryTransferDone? decode(Object? body) {
    final id = _decodeMap(body)?['transferId'];
    return id is String && _transferId.hasMatch(id)
        ? HistoryTransferDone(id)
        : null;
  }
}

Map<Object?, Object?>? _decodeMap(Object? body) {
  if (body is! String || body.length > 4096) return null;
  try {
    final json = jsonDecode(body);
    return json is Map ? json : null;
  } on FormatException {
    return null;
  }
}

/// Archive key (32) + media nonce prefix (7), as the media pipeline uses.
const _archiveKeyLength = 32;
const _archiveNonceLength = 7;
const _wrappedPlainLength = _archiveKeyLength + _archiveNonceLength;

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// A fresh ephemeral X25519 key pair (one per QR code / per offer).
Future<SimpleKeyPair> newHistoryTransferKeyPair() => _x25519.newKeyPair();

/// The public half of [pair] as 32 raw bytes.
Future<Uint8List> historyTransferPublicKey(SimpleKeyPair pair) async =>
    Uint8List.fromList((await pair.extractPublicKey()).bytes);

Future<SecretKey> _wrapKey(SimpleKeyPair own, List<int> otherPublic) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: own,
    remotePublicKey: SimplePublicKey(otherPublic, type: KeyPairType.x25519),
  );
  return _hkdf.deriveKey(
    secretKey: shared,
    nonce: const <int>[],
    info: utf8.encode(historyTransferInfo),
  );
}

/// `wrappedKey` = AES-256-GCM(HKDF-SHA256(X25519(source, target)), key || nonce).
Future<Uint8List> wrapArchiveKey({
  required SimpleKeyPair source,
  required List<int> targetPublicKey,
  required List<int> key,
  required List<int> nonce,
}) async {
  if (key.length != _archiveKeyLength || nonce.length != _archiveNonceLength) {
    throw ArgumentError('archive key or nonce has the wrong length');
  }
  final box = await _aes.encrypt([
    ...key,
    ...nonce,
  ], secretKey: await _wrapKey(source, targetPublicKey));
  return Uint8List.fromList(box.concatenation());
}

/// The archive key and nonce, or null when [wrapped] was not made for
/// [target] (wrong key pair, tampered bytes).
Future<({Uint8List key, Uint8List nonce})?> unwrapArchiveKey({
  required SimpleKeyPair target,
  required List<int> sourcePublicKey,
  required List<int> wrapped,
}) async {
  if (wrapped.length != 12 + _wrappedPlainLength + 16) return null;
  try {
    final plain = await _aes.decrypt(
      SecretBox.fromConcatenation(wrapped, nonceLength: 12, macLength: 16),
      secretKey: await _wrapKey(target, sourcePublicKey),
    );
    return (
      key: Uint8List.fromList(plain.sublist(0, _archiveKeyLength)),
      nonce: Uint8List.fromList(plain.sublist(_archiveKeyLength)),
    );
  } on SecretBoxAuthenticationError {
    return null;
  }
}
