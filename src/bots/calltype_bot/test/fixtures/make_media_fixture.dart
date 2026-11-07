// Regenerates media_voice_v1.json with the APP's encoder (calltype_core
// MediaCipher + MediaInfo, the code the app's MediaService uploads with):
//   dart run test/fixtures/make_media_fixture.dart (copy the JSON from
//   stdout, without dart's "Running build hooks..." line) to
//   test/fixtures/media_voice_v1.json
// The test decrypts the committed blob, so a format change on either side
// shows up as a failing test instead of undecryptable voice messages.
import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/media/media_crypto.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Deterministic plaintext of the fixture (also rebuilt by the test).
Uint8List fixturePlaintext() =>
    Uint8List.fromList(List.generate(3000, (i) => (i * 7) % 251));

Future<void> main() async {
  final plain = fixturePlaintext();
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final nonce = Uint8List.fromList(List.generate(7, (i) => 0xA0 + i));
  const chunkSize = mediaMinChunkSize;
  final cipher = MediaCipher(
    key: key,
    noncePrefix: nonce,
    size: plain.length,
    chunkSize: chunkSize,
  );
  final blob = BytesBuilder();
  for (var i = 0; i < cipher.chunkCount; i++) {
    final start = i * chunkSize;
    final end = start + mediaPlainChunkLength(plain.length, chunkSize, i);
    blob.add(await cipher.encryptChunk(i, plain.sublist(start, end)));
  }
  final info = MediaInfo(
    id: '6f1c2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b',
    kind: MediaKind.voice,
    name: 'voice-20261107-101500.m4a',
    mime: 'audio/mp4',
    size: plain.length,
    sha256: Uint8List.fromList(crypto.sha256.convert(plain).bytes),
    key: key,
    nonce: nonce,
    chunkSize: chunkSize,
    expiresAt: DateTime.utc(2026, 11, 10, 9, 15, 2),
    durationMs: 10400,
    waveform: Uint8List.fromList([0, 64, 128, 255]),
    caption: 'koupit mleko',
  );
  print(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'media': info.toJson(), 'blob': base64Encode(blob.toBytes())}),
  );
}
