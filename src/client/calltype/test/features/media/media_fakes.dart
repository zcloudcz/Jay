import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:calltype/features/media/media_crypto.dart';
import 'package:calltype/features/media/media_message.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype_core/network/media_api.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

/// An in-memory media relay with the contract's behaviour (section 2):
/// staged chunks, resume listing, idempotent complete, ranged download,
/// 404 as [MediaGone]. Knobs inject failures.
class FakeMediaRemote implements MediaRemote {
  final blobs = <String, Uint8List>{};
  final _staged = <String, Map<int, Uint8List>>{};
  final _chunkCounts = <String, int>{};
  final created = <({int size, int chunkSize})>[];
  final puts = <int>[];
  final deleted = <String>[];
  final downloadFrom = <int>[];
  int downloads = 0;

  int? failPutAt;
  Future<void>? putGate;
  int? failAfterBytes;
  bool omitContentLength = false;

  /// Holds a download open until completed (widget tests show progress).
  Completer<void>? downloadGate;
  DateTime expiresAt = DateTime.utc(2030);
  final _random = Random(1);

  String _guid() {
    String hex(int n) =>
        List.generate(n, (_) => _random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-8${hex(3)}-${hex(12)}';
  }

  @override
  Future<MediaUploadCreated> create({
    required int size,
    required int chunkSize,
  }) async {
    created.add((size: size, chunkSize: chunkSize));
    final id = _guid();
    _staged[id] = {};
    final count = (size + chunkSize - 1) ~/ chunkSize;
    _chunkCounts[id] = count;
    return MediaUploadCreated(
      id: id,
      chunkSize: chunkSize,
      chunkCount: count,
      uploadExpiresAt: DateTime.utc(2030),
    );
  }

  @override
  Future<void> putChunk(
    String id,
    int index,
    Uint8List bytes, {
    CancelToken? cancel,
  }) async {
    final gate = putGate;
    if (gate != null) await gate;
    if (cancel?.isCancelled ?? false) throw const MediaCancelled();
    if (failPutAt == index) throw StateError('network down');
    final staged = _staged[id];
    if (staged == null) throw const MediaGone();
    puts.add(index);
    staged[index] = Uint8List.fromList(bytes);
  }

  @override
  Future<MediaUploadStatus> status(String id) async {
    final staged = _staged[id];
    if (staged == null) throw const MediaGone();
    return MediaUploadStatus(
      id: id,
      completed: blobs.containsKey(id),
      chunkCount: _chunkCounts[id]!,
      received: staged.keys.toSet(),
      uploadExpiresAt: DateTime.utc(2030),
    );
  }

  @override
  Future<DateTime> complete(String id) async {
    final staged = _staged[id]!;
    final count = _chunkCounts[id]!;
    final builder = BytesBuilder();
    for (var i = 0; i < count; i++) {
      builder.add(staged[i]!);
    }
    blobs[id] = builder.toBytes();
    return expiresAt;
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    _staged.remove(id);
    blobs.remove(id);
  }

  @override
  Future<MediaDownload> download(
    String id, {
    int from = 0,
    CancelToken? cancel,
  }) async {
    downloads++;
    final blob = blobs[id];
    if (blob == null) throw const MediaGone();
    downloadFrom.add(from);
    final failAfter = failAfterBytes;
    final gate = downloadGate;
    Stream<List<int>> body() async* {
      var sent = 0;
      for (var offset = from; offset < blob.length; offset += 65536) {
        if (gate != null && offset > from) await gate.future;
        if (cancel?.isCancelled ?? false) throw const MediaCancelled();
        final end = min(offset + 65536, blob.length);
        if (failAfter != null && sent + end - offset > failAfter) {
          yield blob.sublist(offset, offset + failAfter - sent);
          throw StateError('connection reset');
        }
        sent += end - offset;
        yield blob.sublist(offset, end);
      }
    }

    return MediaDownload(
      stream: body(),
      contentLength: omitContentLength ? -1 : blob.length - from,
      partial: from > 0,
    );
  }
}

/// Encrypts [plain] like an uploader would and returns the `media` object
/// and the blob the relay stores.
Future<(MediaInfo, Uint8List)> encryptForTest(
  Uint8List plain, {
  String id = '11111111-2222-4333-8444-555555555555',
  MediaKind kind = MediaKind.file,
  String name = 'notes.pdf',
  String mime = 'application/pdf',
  DateTime? expiresAt,
  int? durationMs,
  Uint8List? waveform,
  int chunkSize = mediaMinChunkSize,
}) async {
  final keys = newMediaKey();
  final cipher = MediaCipher(
    key: keys.key,
    noncePrefix: keys.nonce,
    size: plain.length,
    chunkSize: chunkSize,
  );
  final blob = BytesBuilder();
  for (var i = 0; i < cipher.chunkCount; i++) {
    final start = i * chunkSize;
    blob.add(
      await cipher.encryptChunk(
        i,
        plain.sublist(
          start,
          start + mediaPlainChunkLength(plain.length, chunkSize, i),
        ),
      ),
    );
  }
  return (
    MediaInfo(
      id: id,
      kind: kind,
      name: name,
      mime: mime,
      size: plain.length,
      sha256: Uint8List.fromList(crypto.sha256.convert(plain).bytes),
      key: keys.key,
      nonce: keys.nonce,
      chunkSize: chunkSize,
      expiresAt: expiresAt ?? DateTime.utc(2030),
      durationMs: durationMs,
      waveform: waveform,
    ),
    blob.toBytes(),
  );
}
