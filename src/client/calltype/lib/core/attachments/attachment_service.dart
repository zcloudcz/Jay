import 'dart:typed_data';

import 'package:calltype_core/attachments/media_ref.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart' show CancelToken;

export 'package:calltype_core/attachments/media_ref.dart';

/// Frozen interface of encrypted media blobs (M2 §4.7, contracts §5). X0
/// ships it with [UnavailableAttachmentService]; stream M2 (M2-5) provides
/// `DefaultAttachmentService`, and main.dart swaps the provided value.
///
/// Error CODES, never texts: code without a BuildContext reports an enum
/// and a widget maps it to a localized message (see CLAUDE.md).
enum AttachmentErrorCode {
  unavailable,
  tooLarge,
  quotaExceeded,
  network,
  notFoundOrExpired,
  integrity,
  cancelled,
  unsupported,
  storageFull,
  permissionDenied,
}

class AttachmentException implements Exception {
  const AttachmentException(this.code, [this.cause]);
  final AttachmentErrorCode code;
  final Object? cause;

  @override
  String toString() => 'AttachmentException(${code.name})';
}

/// What to upload.
sealed class AttachmentSource {
  const AttachmentSource();

  /// Streamed from disk (native) or from the picked browser file (web) —
  /// a 100 MiB video must never be loaded into memory at once.
  const factory AttachmentSource.file(XFile file) = XFileAttachmentSource;

  /// Small in-memory data: an avatar, a compressed image, a web recording.
  const factory AttachmentSource.memory(Uint8List bytes) =
      MemoryAttachmentSource;
}

class XFileAttachmentSource extends AttachmentSource {
  const XFileAttachmentSource(this.file);
  final XFile file;
}

class MemoryAttachmentSource extends AttachmentSource {
  const MemoryAttachmentSource(this.bytes);
  final Uint8List bytes;
}

/// Everything the MediaRef carries besides the blob itself.
class MediaMetadata {
  const MediaMetadata({
    required this.kind,
    required this.mime,
    this.name,
    this.width,
    this.height,
    this.durationMs,
    this.thumbnail,
    this.waveform,
    this.caption,
  });

  final MediaKind kind;
  final String mime;
  final String? name;
  final int? width;
  final int? height;
  final int? durationMs;
  final Uint8List? thumbnail;
  final Uint8List? waveform;
  final String? caption;
}

enum TransferState { queued, running, paused, done, failed }

class TransferProgress {
  const TransferProgress(
    this.transferId,
    this.doneBytes,
    this.totalBytes,
    this.state, [
    this.error,
  ]);

  final String transferId;
  final int doneBytes;
  final int totalBytes;
  final TransferState state;
  final AttachmentErrorCode? error;

  double get fraction => totalBytes == 0 ? 1 : doneBytes / totalBytes;
}

/// A decrypted, verified blob in the local cache.
abstract class LocalMedia {
  String get blobId;
  int get sizeBytes;
  String get mime;

  /// Native only: absolute path, derived from the stored RELATIVE path.
  String? get filePath;

  /// For images; throws [AttachmentException] `tooLarge` above 50 MiB.
  Future<Uint8List> readBytes();

  /// `file://` on native, `blob:` on the web.
  Future<Uri> playbackUri();

  /// Web: `URL.revokeObjectURL`.
  Future<void> release();
}

abstract class AttachmentService {
  /// Encrypts (with a NEW random key) and uploads; resumable via
  /// [transferId]. The returned MediaRef is directly the body of a `media`
  /// message; the sender's plaintext copy is cached under `ref.blobId`.
  Future<MediaRef> upload(
    AttachmentSource source,
    MediaMetadata meta, {
    String? transferId,
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  });

  /// Downloads (Range-resumable), verifies GCM + sha256 + size, caches.
  Future<LocalMedia> fetch(
    MediaRef ref, {
    String? transferId,
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  });

  Future<LocalMedia?> cached(MediaRef ref);
  Stream<TransferProgress> watch(String transferId);

  /// Uploader only; 404/204 both mean "gone".
  Future<void> deleteRemote(String blobId);
  Future<void> deleteLocal(String blobId);
  Future<int> cacheSizeBytes();
}

/// Provided until M2-5 lands: every operation fails with
/// [AttachmentErrorCode.unavailable], which the UI maps to "not available
/// in this version" — never a crash, never a silent no-op that would look
/// like a successful upload.
class UnavailableAttachmentService implements AttachmentService {
  const UnavailableAttachmentService();

  static Never _unavailable() =>
      throw const AttachmentException(AttachmentErrorCode.unavailable);

  @override
  Future<MediaRef> upload(
    AttachmentSource source,
    MediaMetadata meta, {
    String? transferId,
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  }) async => _unavailable();

  @override
  Future<LocalMedia> fetch(
    MediaRef ref, {
    String? transferId,
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  }) async => _unavailable();

  @override
  Future<LocalMedia?> cached(MediaRef ref) async => _unavailable();

  @override
  Stream<TransferProgress> watch(String transferId) =>
      Stream.error(const AttachmentException(AttachmentErrorCode.unavailable));

  @override
  Future<void> deleteRemote(String blobId) async => _unavailable();

  @override
  Future<void> deleteLocal(String blobId) async => _unavailable();

  @override
  Future<int> cacheSizeBytes() async => _unavailable();
}
