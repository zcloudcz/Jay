import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypted media chunk format (contract section 1).
///
/// Each plaintext chunk `i` of `n` is sealed separately with AES-256-GCM
/// under a fresh per-file key; the 12-byte nonce is
/// `prefix(7) || uint32_be(i) || final(1)`. The index stops chunks being
/// reordered, the final flag stops truncation at a chunk boundary (the last
/// chunk only verifies with flag 1), and the receiver additionally rejects
/// any blob whose length is not exactly `size + 16 * n`. Per-chunk tags let
/// both sides stream from and to disk instead of holding a file in memory.

const mediaTagLength = 16;
const mediaNoncePrefixLength = 7;
final mediaAad = utf8.encode('jay-media-v1');

/// The blob failed authentication: wrong length, a bad tag, a reordered or
/// missing chunk. The partial output is discarded.
class MediaTampered implements Exception {
  const MediaTampered(this.reason);
  final String reason;
  @override
  String toString() => 'MediaTampered: $reason';
}

/// Every chunk verified but the whole plaintext does not have the SHA-256
/// the message promised (wrong key material in the message, or a bug).
class MediaHashMismatch implements Exception {
  const MediaHashMismatch();
  @override
  String toString() => 'MediaHashMismatch';
}

int mediaChunkCount(int size, int chunkSize) =>
    max(1, (size + chunkSize - 1) ~/ chunkSize);

int mediaEncryptedSize(int size, int chunkSize) =>
    size + mediaTagLength * mediaChunkCount(size, chunkSize);

/// Plaintext length of chunk [index].
int mediaPlainChunkLength(int size, int chunkSize, int index) {
  final start = index * chunkSize;
  return min(chunkSize, size - start);
}

Uint8List mediaChunkNonce(List<int> prefix, int index, {required bool last}) {
  if (prefix.length != mediaNoncePrefixLength) {
    throw ArgumentError('nonce prefix must be 7 bytes');
  }
  final nonce = Uint8List(12)..setRange(0, 7, prefix);
  ByteData.sublistView(nonce).setUint32(7, index);
  nonce[11] = last ? 1 : 0;
  return nonce;
}

/// Fresh random key (32 bytes) and nonce prefix (7 bytes) for one file.
({Uint8List key, Uint8List nonce}) newMediaKey([Random? random]) {
  final rng = random ?? Random.secure();
  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  return (key: bytes(32), nonce: bytes(mediaNoncePrefixLength));
}

/// Seals / opens single chunks of one file.
class MediaCipher {
  MediaCipher({
    required List<int> key,
    required this.noncePrefix,
    required this.size,
    required this.chunkSize,
  }) : _key = SecretKey(key),
       chunkCount = mediaChunkCount(size, chunkSize);

  static final _aes = AesGcm.with256bits();

  final SecretKey _key;
  final List<int> noncePrefix;
  final int size;
  final int chunkSize;
  final int chunkCount;

  int get encryptedChunkSize => chunkSize + mediaTagLength;
  int get encryptedSize => size + mediaTagLength * chunkCount;

  /// Encrypted length of chunk [index].
  int encryptedChunkLength(int index) =>
      mediaPlainChunkLength(size, chunkSize, index) + mediaTagLength;

  /// `ciphertext || tag` of plaintext chunk [index]. Deterministic for a
  /// given key / nonce / index, which makes re-uploading a chunk after an
  /// interruption idempotent.
  Future<Uint8List> encryptChunk(int index, List<int> plain) async {
    if (index < 0 || index >= chunkCount) throw RangeError.index(index, this);
    if (plain.length != mediaPlainChunkLength(size, chunkSize, index)) {
      throw ArgumentError('chunk $index has the wrong length');
    }
    final box = await _aes.encrypt(
      plain,
      secretKey: _key,
      nonce: mediaChunkNonce(noncePrefix, index, last: index == chunkCount - 1),
      aad: mediaAad,
    );
    final out = Uint8List(box.cipherText.length + mediaTagLength)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    return out;
  }

  /// Opens encrypted chunk [index]; throws [MediaTampered] on a wrong
  /// length or a failed tag.
  Future<Uint8List> decryptChunk(int index, List<int> sealed) async {
    if (index < 0 || index >= chunkCount) {
      throw const MediaTampered('chunk index out of range');
    }
    if (sealed.length != encryptedChunkLength(index)) {
      throw const MediaTampered('chunk length');
    }
    final cut = sealed.length - mediaTagLength;
    try {
      final plain = await _aes.decrypt(
        SecretBox(
          sealed.sublist(0, cut),
          nonce: mediaChunkNonce(
            noncePrefix,
            index,
            last: index == chunkCount - 1,
          ),
          mac: Mac(sealed.sublist(cut)),
        ),
        secretKey: _key,
        aad: mediaAad,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const MediaTampered('tag');
    }
  }

  /// Decrypts an encrypted stream that starts at chunk [startChunk] and must
  /// end exactly after the last chunk. [write] receives each verified
  /// plaintext chunk in order; at most one encrypted chunk is buffered.
  Future<void> decryptStream(
    Stream<List<int>> encrypted, {
    int startChunk = 0,
    required Future<void> Function(int index, Uint8List plain) write,
  }) async {
    var index = startChunk;
    var buffer = BytesBuilder(copy: false);
    Future<void> flush(Uint8List sealed) async {
      final plain = await decryptChunk(index, sealed);
      await write(index, plain);
      index++;
    }

    await for (final data in encrypted) {
      var offset = 0;
      while (offset < data.length) {
        if (index >= chunkCount) {
          throw const MediaTampered('longer than declared');
        }
        final need = encryptedChunkLength(index) - buffer.length;
        final take = min(need, data.length - offset);
        buffer.add(
          data is Uint8List
              ? Uint8List.sublistView(data, offset, offset + take)
              : data.sublist(offset, offset + take),
        );
        offset += take;
        if (buffer.length == encryptedChunkLength(index)) {
          final sealed = buffer.takeBytes();
          buffer = BytesBuilder(copy: false);
          await flush(sealed);
        }
      }
    }
    if (buffer.isNotEmpty || index != chunkCount) {
      throw const MediaTampered('shorter than declared');
    }
  }
}
