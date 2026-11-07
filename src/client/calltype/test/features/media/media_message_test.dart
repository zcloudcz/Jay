import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype/features/chat/attachment.dart';
import 'package:calltype/features/media/media_message.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// Contract section 3: the `media` object, its validation and the fallback
/// text old clients show.
void main() {
  final valid = <String, Object?>{
    'v': 1,
    'id': '6f1c2a3b-1111-4222-8333-444455556666',
    'kind': 'voice',
    'name': 'voice-20261107-101500.m4a',
    'mime': 'audio/mp4',
    'size': 183422,
    'sha256': base64Encode(List.filled(32, 1)),
    'key': base64Encode(List.filled(32, 2)),
    'nonce': base64Encode(List.filled(7, 3)),
    'chunkSize': 4194304,
    'expiresAt': '2026-11-10T09:15:02Z',
    'durationMs': 12345,
    'waveform': base64Encode(List.filled(64, 128)),
    'caption': 'optional text',
  };

  test('decodes the contract example and encodes it back', () {
    final info = MediaInfo.tryParse(valid)!;
    expect(info.kind, MediaKind.voice);
    expect(info.size, 183422);
    expect(info.durationMs, 12345);
    expect(info.expiresAt, DateTime.utc(2026, 11, 10, 9, 15, 2));
    expect(info.waveform, hasLength(64));
    final again = MediaInfo.tryParse(jsonDecode(info.encode()))!;
    expect(again.toJson(), info.toJson());
    expect(jsonDecode(info.encode())['expiresAt'], '2026-11-10T09:15:02.000Z');
  });

  test('unknown keys are ignored, an unknown kind becomes a file', () {
    final info = MediaInfo.tryParse({...valid, 'kind': 'hologram', 'x': 1})!;
    expect(info.kind, MediaKind.file);
  });

  final invalid = <String, Map<String, Object?>>{
    'newer version': {...valid, 'v': 2},
    'id not a guid': {...valid, 'id': '../../etc'},
    'empty id outside a draft': {...valid, 'id': ''},
    'name with a slash': {...valid, 'name': 'a/b.m4a'},
    'name with a control char': {...valid, 'name': 'a\u0001.m4a'},
    'mime without subtype': {...valid, 'mime': 'audio'},
    'negative size': {...valid, 'size': -1},
    'size over the cap': {...valid, 'size': mediaMaxBytes + 1},
    'short key': {...valid, 'key': base64Encode(List.filled(31, 2))},
    'long nonce': {...valid, 'nonce': base64Encode(List.filled(8, 3))},
    'short sha256': {...valid, 'sha256': base64Encode(List.filled(16, 1))},
    'key not base64': {...valid, 'key': '***'},
    'chunk size too small': {...valid, 'chunkSize': 1024},
    'chunk size too large': {...valid, 'chunkSize': 16 * 1024 * 1024},
    'missing expiry': {...valid}..remove('expiresAt'),
    'negative duration': {...valid, 'durationMs': -5},
    'zero width': {...valid, 'width': 0},
    'thumbnail over 24 KiB': {
      ...valid,
      'thumbnail': base64Encode(Uint8List(24 * 1024 + 1)),
    },
    'waveform over 128 bars': {
      ...valid,
      'waveform': base64Encode(Uint8List(129)),
    },
    'caption over 4096 chars': {...valid, 'caption': 'x' * 4097},
    'size as a string': {...valid, 'size': '183422'},
  };
  for (final entry in invalid.entries) {
    test('rejects: ${entry.key}', () {
      expect(MediaInfo.tryParse(entry.value), isNull);
    });
  }

  test('a draft (own unfinished upload) may lack id and expiry', () {
    final draft = {...valid, 'id': ''}..remove('expiresAt');
    expect(MediaInfo.tryParse(draft), isNull);
    final info = MediaInfo.tryParse(draft, draft: true)!;
    expect(info.isDraft, isTrue);
    expect(MediaInfo.tryDecode(jsonEncode(draft))!.isDraft, isTrue);
    expect(MediaInfo.tryDecode('not json'), isNull);
  });

  test('expiry', () {
    final info = MediaInfo.tryParse(valid)!;
    expect(info.isExpired(DateTime.utc(2026, 11, 10, 9)), isFalse);
    expect(info.isExpired(DateTime.utc(2026, 11, 10, 10)), isTrue);
  });

  test('fallback body for old clients, with the caption on its own line', () {
    final voice = MediaInfo.tryParse(valid)!;
    expect(
      mediaFallbackBody(l10nEn, voice),
      '\u{1F3A4} Voice message (0:12). Update Jay to play it.\noptional text',
    );
    final file = MediaInfo.tryParse(
      {...valid, 'kind': 'file', 'name': 'report.pdf', 'size': 12400000}
        ..remove('caption'),
    )!;
    expect(
      mediaFallbackBody(l10nEn, file),
      '\u{1F4CE} report.pdf (12.4 MB). Update Jay to download it.',
    );
  });

  test('reply summary: caption first, else kind and duration or name', () {
    expect(mediaSummary(l10nEn, MediaInfo.tryParse(valid)!), 'optional text');
    final noCaption = {...valid}..remove('caption');
    expect(
      mediaSummary(l10nEn, MediaInfo.tryParse(noCaption)!),
      'Voice message (0:12)',
    );
    expect(
      mediaSummary(
        l10nEn,
        MediaInfo.tryParse({...noCaption, 'kind': 'file', 'name': 'a.zip'})!,
      ),
      'a.zip',
    );
  });

  test('kind and MIME type from a file name', () {
    expect(mediaKindFor('clip.MOV'), MediaKind.video);
    expect(mediaKindFor('song.mp3'), MediaKind.audio);
    expect(mediaKindFor('x', mime: 'audio/ogg'), MediaKind.audio);
    expect(mediaKindFor('scan.png'), MediaKind.image);
    expect(mediaKindFor('report.pdf'), MediaKind.file);
    expect(mediaMimeFor('clip.mp4'), 'video/mp4');
    expect(mediaMimeFor('unknown.xyz'), 'application/octet-stream');
    expect(
      normalizeMediaMime('audio/webm;codecs=opus', 'v.webm'),
      'audio/webm',
    );
    expect(normalizeMediaMime('garbage', 'v.m4a'), 'audio/mp4');
    expect(normalizeMediaMime(null, 'v.mp4'), 'video/mp4');
  });

  test('durations and sizes', () {
    expect(formatMediaDuration(0), '0:00');
    expect(formatMediaDuration(65000), '1:05');
    expect(formatMediaDuration(3725000), '1:02:05');
    expect(formatMediaSize(999), '999 B');
    expect(formatMediaSize(1500), '1.5 KB');
    expect(formatMediaSize(5367660544), '5.4 GB');
  });

  test('waveform is reduced to 64 bars of 0..255 peaks', () {
    final bars = reduceWaveform([for (var i = 0; i < 640; i++) i % 10 / 9]);
    expect(bars, hasLength(64));
    expect(bars.every((b) => b == 255), isTrue);
    expect(reduceWaveform([0.5]), hasLength(64));
    expect(reduceWaveform(const []), isEmpty);
  });

  group('the inline `file` type still decodes', () {
    final bytes = Uint8List.fromList('hello'.codeUnits);
    test('without a caption', () {
      final body = jsonEncode({'name': 'a.txt', 'data': base64Encode(bytes)});
      expect(Attachment.decode(body).bytes, bytes);
    });
    test('with the optional caption of the composer branch', () {
      final body = jsonEncode({
        'name': 'a.txt',
        'data': base64Encode(bytes),
        'caption': 'look',
      });
      final file = Attachment.decode(body);
      expect(file.name, 'a.txt');
      expect(file.bytes, bytes);
    });
  });
}
