import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/attachments/media_ref.dart';
import 'package:test/test.dart';

/// Body shape copied from the contract (M2 §4.6), not from the class — so a
/// drift between the two is caught here.
Map<String, Object?> contractBody() => {
  'v': 1,
  'kind': 'image',
  'blobId': '5c0b8a4e-1f7d-4c52-9b1e-0f3a2d6c7e81',
  'key': base64Encode(List.filled(32, 7)),
  'sha256': 'a' * 64,
  'size': 183422,
  'mime': 'image/jpeg',
  'name': 'IMG_2041.jpg',
  'width': 2048,
  'height': 1536,
  'durationMs': 31000,
  'thumbnail': base64Encode([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]),
  'waveform': base64Encode(List.filled(64, 128)),
  'caption': 'Text pod obrázkem',
  'exp': '2026-10-29T12:00:00Z',
};

String body([void Function(Map<String, Object?> m)? change]) {
  final m = contractBody();
  change?.call(m);
  return jsonEncode(m);
}

void main() {
  test('decodes the contract example with every field', () {
    final ref = MediaRef.decode(body());
    expect(ref.kind, MediaKind.image);
    expect(ref.blobId, '5c0b8a4e-1f7d-4c52-9b1e-0f3a2d6c7e81');
    expect(ref.key, hasLength(32));
    expect(ref.size, 183422);
    expect(ref.mime, 'image/jpeg');
    expect(ref.name, 'IMG_2041.jpg');
    expect(ref.width, 2048);
    expect(ref.height, 1536);
    expect(ref.durationMs, 31000);
    expect(ref.thumbnail!.take(2), [0xFF, 0xD8]);
    expect(ref.waveform, hasLength(64));
    expect(ref.caption, 'Text pod obrázkem');
    expect(ref.exp, DateTime.utc(2026, 10, 29, 12));
  });

  test('round-trips through encode/decode and toJson/fromJson', () {
    final ref = MediaRef.decode(body());
    final again = MediaRef.decode(ref.encode());
    expect(again.toJson(), ref.toJson());
    expect(MediaRef.fromJson(ref.toJson()).encode(), ref.encode());
  });

  test('optional fields may be absent and are omitted when encoding', () {
    final ref = MediaRef.decode(
      body((m) {
        for (final k in [
          'name',
          'width',
          'height',
          'durationMs',
          'thumbnail',
          'waveform',
          'caption',
          'exp',
        ]) {
          m.remove(k);
        }
      }),
    );
    expect(ref.name, isNull);
    expect(ref.toJson().keys, {
      'v',
      'kind',
      'blobId',
      'key',
      'sha256',
      'size',
      'mime',
    });
  });

  test('unknown keys are ignored (forward compatibility)', () {
    final ref = MediaRef.decode(body((m) => m['futureField'] = {'x': 1}));
    expect(ref.kind, MediaKind.image);
    expect(ref.toJson().containsKey('futureField'), isFalse);
  });

  test('every kind is accepted', () {
    for (final kind in MediaKind.values) {
      expect(MediaRef.decode(body((m) => m['kind'] = kind.name)).kind, kind);
    }
  });

  group('rejects', () {
    final cases = <String, void Function(Map<String, Object?>)>{
      'version 2': (m) => m['v'] = 2,
      'missing version': (m) => m.remove('v'),
      'unknown kind': (m) => m['kind'] = 'sticker',
      'blobId not a UUID': (m) => m['blobId'] = '../../etc/passwd',
      'missing blobId': (m) => m.remove('blobId'),
      'key 31 bytes': (m) => m['key'] = base64Encode(List.filled(31, 1)),
      'key 33 bytes': (m) => m['key'] = base64Encode(List.filled(33, 1)),
      'key not base64': (m) => m['key'] = 'not base64!',
      'uppercase sha256': (m) => m['sha256'] = 'A' * 64,
      'short sha256': (m) => m['sha256'] = 'a' * 63,
      'negative size': (m) => m['size'] = -1,
      'size over 100 MiB': (m) => m['size'] = 104857601,
      'fractional size': (m) => m['size'] = 1.5,
      'size as string': (m) => m['size'] = '10',
      'mime without slash': (m) => m['mime'] = 'jpeg',
      'mime uppercase': (m) => m['mime'] = 'Image/JPEG',
      'mime too long': (m) => m['mime'] = 'a/${'b' * 126}',
      'name with slash': (m) => m['name'] = 'a/b.jpg',
      'name with backslash': (m) => m['name'] = r'a\b.jpg',
      'name with control char': (m) => m['name'] = 'a\u0007.jpg',
      'blank name': (m) => m['name'] = '   ',
      'name too long': (m) => m['name'] = 'a' * 256,
      'width 0': (m) => m['width'] = 0,
      'height over 16384': (m) => m['height'] = 16385,
      'negative duration': (m) => m['durationMs'] = -1,
      'duration over 24 h': (m) => m['durationMs'] = 86400001,
      'thumbnail not JPEG': (m) =>
          m['thumbnail'] = base64Encode([0x89, 0x50, 0x4E, 0x47]),
      'thumbnail too large': (m) => m['thumbnail'] = base64Encode([
        0xFF,
        0xD8,
        ...List.filled(16383, 0),
      ]),
      'waveform too long': (m) =>
          m['waveform'] = base64Encode(List.filled(257, 0)),
      'caption too long': (m) => m['caption'] = 'a' * 4097,
      'exp not a date': (m) => m['exp'] = 'tomorrow',
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          () => MediaRef.decode(body(entry.value)),
          throwsFormatException,
        );
      });
    }

    test('a body over 32 768 characters', () {
      expect(
        () => MediaRef.decode(body((m) => m['pad'] = 'x' * 32768)),
        throwsFormatException,
      );
    });

    test('non-JSON and non-object bodies', () {
      expect(() => MediaRef.decode('not json'), throwsFormatException);
      expect(() => MediaRef.decode('[1,2]'), throwsFormatException);
      expect(() => MediaRef.decode('"str"'), throwsFormatException);
    });
  });

  test('limits are inclusive', () {
    final ref = MediaRef.decode(
      body((m) {
        m['size'] = MediaRef.maxSize;
        m['width'] = 16384;
        m['height'] = 1;
        m['durationMs'] = 86400000;
        m['caption'] = 'a' * 4096;
        m['name'] = 'a' * 255;
        m['waveform'] = base64Encode(List.filled(256, 0));
        m['thumbnail'] = base64Encode([0xFF, 0xD8, ...List.filled(16382, 0)]);
      }),
    );
    expect(ref.size, MediaRef.maxSize);
  });

  test('the constructor refuses to build an invalid reference', () {
    expect(
      () => MediaRef(
        kind: MediaKind.file,
        blobId: 'x',
        key: Uint8List(32),
        sha256: 'a' * 64,
        size: 1,
        mime: 'a/b',
      ),
      throwsArgumentError,
    );
  });

  test('encryptedSize adds one 16-byte tag per 64 KiB segment', () {
    MediaRef sized(int size) =>
        MediaRef.decode(body((m) => m['size'] = size));
    expect(sized(0).encryptedSize, 16); // empty file = one empty segment
    expect(sized(1).encryptedSize, 17);
    expect(sized(65536).encryptedSize, 65536 + 16);
    expect(sized(65537).encryptedSize, 65537 + 32);
    expect(sized(183422).encryptedSize, 183422 + 16 * 3);
  });

  test('copyWith changes only the given fields and re-validates', () {
    final ref = MediaRef.decode(body());
    final copy = ref.copyWith(caption: 'new', size: 10);
    expect(copy.caption, 'new');
    expect(copy.size, 10);
    expect(copy.blobId, ref.blobId);
    expect(() => ref.copyWith(mime: 'bad'), throwsArgumentError);
  });

  test('key bytes are copied, not aliased', () {
    final key = Uint8List(32);
    final ref = MediaRef(
      kind: MediaKind.file,
      blobId: '5c0b8a4e-1f7d-4c52-9b1e-0f3a2d6c7e81',
      key: key,
      sha256: 'a' * 64,
      size: 1,
      mime: 'application/octet-stream',
    );
    key[0] = 9;
    expect(ref.key[0], 0);
  });
}
