import 'dart:async';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/media_api.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'media_crypto.dart';
import 'media_message.dart';
import 'media_store.dart';

/// The server no longer has the media (404 / 410, contract 2.6): expired,
/// deleted, or the upload window passed.
class MediaGone implements Exception {
  const MediaGone();
}

/// The user cancelled the transfer.
class MediaCancelled implements Exception {
  const MediaCancelled();
}

/// The relay endpoints (contract section 2) behind a seam, so the transfer
/// logic is tested against a fake server without Dio.
abstract class MediaRemote {
  Future<MediaUploadCreated> create({
    required int size,
    required int chunkSize,
  });
  Future<void> putChunk(
    String id,
    int index,
    Uint8List bytes, {
    CancelToken? cancel,
  });
  Future<MediaUploadStatus> status(String id);
  Future<DateTime> complete(String id);
  Future<void> delete(String id);
  Future<MediaDownload> download(
    String id, {
    int from = 0,
    CancelToken? cancel,
  });
}

/// [MediaRemote] on the app's authenticated [ApiClient].
class ApiMediaRemote implements MediaRemote {
  ApiMediaRemote(this._api);
  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) throw const MediaCancelled();
      final status = e.response?.statusCode;
      if (status == 404 || status == 410) throw const MediaGone();
      rethrow;
    }
  }

  @override
  Future<MediaUploadCreated> create({
    required int size,
    required int chunkSize,
  }) => _call(() => _api.createMedia(size: size, chunkSize: chunkSize));

  @override
  Future<void> putChunk(
    String id,
    int index,
    Uint8List bytes, {
    CancelToken? cancel,
  }) => _call(() => _api.putMediaChunk(id, index, bytes, cancelToken: cancel));

  @override
  Future<MediaUploadStatus> status(String id) =>
      _call(() => _api.getMediaUploadStatus(id));

  @override
  Future<DateTime> complete(String id) => _call(() => _api.completeMedia(id));

  @override
  Future<void> delete(String id) => _call(() => _api.deleteMedia(id));

  @override
  Future<MediaDownload> download(
    String id, {
    int from = 0,
    CancelToken? cancel,
  }) => _call(() => _api.downloadMedia(id, from: from, cancelToken: cancel));
}

/// Placeholder until main() wires the real API; every call fails.
class _UnconfiguredRemote implements MediaRemote {
  Never _fail() => throw StateError('MediaService is not configured');
  @override
  Future<MediaUploadCreated> create({
    required int size,
    required int chunkSize,
  }) async => _fail();
  @override
  Future<void> putChunk(
    String id,
    int index,
    Uint8List bytes, {
    CancelToken? cancel,
  }) async => _fail();
  @override
  Future<MediaUploadStatus> status(String id) async => _fail();
  @override
  Future<DateTime> complete(String id) async => _fail();
  @override
  Future<void> delete(String id) async => _fail();
  @override
  Future<MediaDownload> download(
    String id, {
    int from = 0,
    CancelToken? cancel,
  }) async => _fail();
}

/// What a bubble shows about a transfer.
enum MediaPhase {
  /// Nothing running (not downloaded yet, or finished).
  idle,
  uploading,
  downloading,

  /// Network or server error; Retry.
  failed,

  /// Tag, length or hash check failed: "File is damaged".
  damaged,

  /// 404 / 410: the server copy is gone.
  expired,
}

@immutable
class MediaProgress {
  const MediaProgress(this.phase, [this.fraction]);
  final MediaPhase phase;

  /// 0..1, null when unknown.
  final double? fraction;
}

/// Uploads, downloads and local copies of encrypted media (contract
/// sections 1, 4). One instance for the app ([instance]) so a transfer
/// survives leaving the chat screen; its progress is a [ChangeNotifier]
/// the bubbles listen to.
///
/// Never downloads on its own (M8): [download] runs only from a tap.
class MediaService extends ChangeNotifier {
  MediaService({
    required MediaRemote remote,
    required this.store,
    bool web = kIsWeb,
    this.uploadConcurrency = 2,
  }) : _remote = remote,
       maxBytes = web ? mediaMaxBytesWeb : mediaMaxBytes,
       _web = web;

  /// Replaced in main() (real API) and in tests (fakes).
  static MediaService instance = MediaService(
    remote: _UnconfiguredRemote(),
    store: MediaStore.create(),
  );

  final MediaRemote _remote;
  final MediaStore store;
  final bool _web;

  /// Plaintext cap of this platform (5 GiB - 1 MiB, web 512 MiB).
  final int maxBytes;

  /// Chunk PUTs in flight per upload (contract 4.1, "bounded concurrency").
  final int uploadConcurrency;

  final _uploads = <String, MediaProgress>{};
  final _downloads = <String, MediaProgress>{};
  final _uploadTokens = <String, CancelToken>{};
  final _downloadTokens = <String, CancelToken>{};
  final _local = <String, bool>{};
  final _checking = <String>{};

  bool get isWeb => _web;

  /// Upload progress of an own message, by message id.
  MediaProgress? uploadOf(String messageId) => _uploads[messageId];

  /// Download progress, by media id.
  MediaProgress? downloadOf(String mediaId) => _downloads[mediaId];

  bool isUploading(String messageId) => _uploadTokens.containsKey(messageId);

  /// Whether the decrypted file is on this device; null while unknown (a
  /// check is started and listeners are notified with the answer).
  bool? isLocal(MediaInfo info) {
    final known = _local[info.id];
    if (known != null || info.isDraft) return known;
    if (_checking.add(info.id)) {
      unawaited(
        store
            .exists(info.id, info.name)
            .then(
              (exists) {
                _local[info.id] = exists;
                _checking.remove(info.id);
                notifyListeners();
              },
              onError: (Object _) {
                _local[info.id] = false;
                _checking.remove(info.id);
                notifyListeners();
              },
            ),
      );
    }
    return null;
  }

  void _set(Map<String, MediaProgress> map, String key, MediaProgress? value) {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
    notifyListeners();
  }

  /// Copies a picked file into `up-<messageId>` (streamed, hashed). Throws
  /// [MediaTooLarge] beyond [maxBytes].
  Future<StoredMedia> importForUpload(
    String messageId,
    String name,
    Stream<List<int>> source,
  ) => store.import(uploadFolder(messageId), name, source, maxBytes: maxBytes);

  static String uploadFolder(String messageId) => 'up-$messageId';

  /// Encrypts and uploads [draft] (stored under [folder]), resuming an
  /// earlier attempt when [draft] already has a server id. [persist] is
  /// told every new id / key / folder so a restart can resume (contract
  /// 4.1). Returns the final `media` object with id and expiry.
  Future<MediaInfo> upload(
    String messageId,
    MediaInfo draft, {
    required String folder,
    required Future<void> Function(MediaInfo info, String folder) persist,
  }) async {
    if (_uploadTokens.containsKey(messageId)) {
      throw StateError('upload already running');
    }
    final token = CancelToken();
    _uploadTokens[messageId] = token;
    _set(_uploads, messageId, const MediaProgress(MediaPhase.uploading, 0));
    var info = draft;
    var currentFolder = folder;
    try {
      var received = <int>{};
      if (!info.isDraft) {
        try {
          final status = await _remote.status(info.id);
          if (status.completed) {
            final expiresAt = await _remote.complete(info.id);
            info = info.copyWith(expiresAt: expiresAt);
            await persist(info, currentFolder);
            return _finishUpload(messageId, info);
          }
          received = status.received;
        } on MediaGone {
          // The 24 h upload window passed (or the server lost it): start
          // over with a NEW key, never reuse a key for a new blob.
          final fresh = newMediaKey();
          info = MediaInfo(
            id: '',
            kind: info.kind,
            name: info.name,
            mime: info.mime,
            size: info.size,
            sha256: info.sha256,
            key: fresh.key,
            nonce: fresh.nonce,
            chunkSize: info.chunkSize,
            durationMs: info.durationMs,
            width: info.width,
            height: info.height,
            thumbnail: info.thumbnail,
            waveform: info.waveform,
            caption: info.caption,
          );
          await persist(info, currentFolder);
        }
      }
      final cipher = MediaCipher(
        key: info.key,
        noncePrefix: info.nonce,
        size: info.size,
        chunkSize: info.chunkSize,
      );
      if (info.isDraft) {
        final created = await _remote.create(
          size: cipher.encryptedSize,
          chunkSize: cipher.encryptedChunkSize,
        );
        info = info.copyWith(id: created.id);
        // The local copy moves to its final folder right away, so the
        // persisted state never points at a folder that no longer exists.
        await store.renameFolder(currentFolder, info.id);
        currentFolder = info.id;
        await persist(info, currentFolder);
      }
      _checkCancelled(token);
      final pending = [
        for (var i = 0; i < cipher.chunkCount; i++)
          if (!received.contains(i)) i,
      ];
      final total = cipher.encryptedSize;
      var sent = 0;
      for (final i in received) {
        if (i < cipher.chunkCount) sent += cipher.encryptedChunkLength(i);
      }
      final reader = await store.openReader(currentFolder, info.name);
      try {
        var next = 0;
        Future<void> worker() async {
          while (next < pending.length) {
            _checkCancelled(token);
            final index = pending[next++];
            final plain = await reader.read(
              index * info.chunkSize,
              mediaPlainChunkLength(info.size, info.chunkSize, index),
            );
            final sealed = await cipher.encryptChunk(index, plain);
            _checkCancelled(token);
            await _remote.putChunk(info.id, index, sealed, cancel: token);
            sent += sealed.length;
            _set(
              _uploads,
              messageId,
              MediaProgress(
                MediaPhase.uploading,
                total == 0 ? 1 : sent / total,
              ),
            );
          }
        }

        await Future.wait([
          for (var w = 0; w < uploadConcurrency; w++) worker(),
        ]);
      } finally {
        await reader.close();
      }
      _checkCancelled(token);
      final expiresAt = await _remote.complete(info.id);
      info = info.copyWith(expiresAt: expiresAt);
      await persist(info, currentFolder);
      return _finishUpload(messageId, info);
    } catch (e) {
      final cancelled = token.isCancelled || e is MediaCancelled;
      if (cancelled && !info.isDraft) {
        // Cancel = withdraw the blob (contract 4.1); best effort, the
        // server's 24 h upload window cleans up anyway.
        try {
          await _remote.delete(info.id);
        } catch (_) {}
      }
      _set(
        _uploads,
        messageId,
        cancelled ? null : const MediaProgress(MediaPhase.failed),
      );
      if (cancelled) throw const MediaCancelled();
      rethrow;
    } finally {
      _uploadTokens.remove(messageId);
    }
  }

  MediaInfo _finishUpload(String messageId, MediaInfo info) {
    _local[info.id] = true;
    _set(_uploads, messageId, null);
    return info;
  }

  static void _checkCancelled(CancelToken token) {
    if (token.isCancelled) throw const MediaCancelled();
  }

  void cancelUpload(String messageId) => _uploadTokens[messageId]?.cancel();

  /// Downloads, verifies and stores [info] (a user tap, never automatic).
  /// Resumes after the chunks a previous attempt already decrypted to the
  /// `.part` file. Errors end up in [downloadOf]; nothing is thrown.
  Future<void> download(MediaInfo info) async {
    if (info.isDraft || _downloadTokens.containsKey(info.id)) return;
    if (info.size > maxBytes) return;
    final token = CancelToken();
    _downloadTokens[info.id] = token;
    _set(_downloads, info.id, const MediaProgress(MediaPhase.downloading, 0));
    MediaPartWriter? part;
    try {
      final cipher = MediaCipher(
        key: info.key,
        noncePrefix: info.nonce,
        size: info.size,
        chunkSize: info.chunkSize,
      );
      part = await store.openPart(info.id, info.name);
      // Only whole verified chunks count; a crash mid-chunk leaves a tail
      // that is cut off and fetched again.
      var done = part.existingLength ~/ info.chunkSize;
      if (done >= cipher.chunkCount) done = cipher.chunkCount - 1;
      if (part.existingLength != done * info.chunkSize) {
        await part.truncate(done * info.chunkSize);
      }
      var digest = _DigestSink();
      var hash = crypto.sha256.startChunkedConversion(digest);
      if (done > 0) {
        await for (final data in part.readExisting()) {
          hash.add(data);
        }
      }
      final from = done * cipher.encryptedChunkSize;
      final response = await _remote.download(
        info.id,
        from: from,
        cancel: token,
      );
      if (from > 0 && !response.partial) {
        // The server ignored the Range header: start from scratch.
        await part.truncate(0);
        done = 0;
        digest = _DigestSink();
        hash = crypto.sha256.startChunkedConversion(digest);
      }
      final remaining = cipher.encryptedSize - done * cipher.encryptedChunkSize;
      if (response.contentLength >= 0 && response.contentLength != remaining) {
        throw const MediaTampered('length');
      }
      var written = done * cipher.encryptedChunkSize;
      await cipher.decryptStream(
        response.stream,
        startChunk: done,
        write: (index, plain) async {
          _checkCancelled(token);
          await part!.append(plain);
          hash.add(plain);
          written += plain.length + mediaTagLength;
          _set(
            _downloads,
            info.id,
            MediaProgress(
              MediaPhase.downloading,
              written / cipher.encryptedSize,
            ),
          );
        },
      );
      hash.close();
      if (!_sameBytes(digest.value!.bytes, info.sha256)) {
        throw const MediaHashMismatch();
      }
      await part.commit();
      _local[info.id] = true;
      _set(_downloads, info.id, null);
    } on MediaTampered {
      await part?.discard();
      _set(_downloads, info.id, const MediaProgress(MediaPhase.damaged));
    } on MediaHashMismatch {
      await part?.discard();
      _set(_downloads, info.id, const MediaProgress(MediaPhase.damaged));
    } on MediaGone {
      await part?.discard();
      _set(_downloads, info.id, const MediaProgress(MediaPhase.expired));
    } catch (e) {
      // Network error or cancel: the verified chunks stay in `.part` for
      // the next tap (contract 4.3, resume).
      await part?.close();
      final cancelled = token.isCancelled || e is MediaCancelled;
      _set(
        _downloads,
        info.id,
        cancelled ? null : const MediaProgress(MediaPhase.failed),
      );
    } finally {
      _downloadTokens.remove(info.id);
    }
  }

  void cancelDownload(String mediaId) => _downloadTokens[mediaId]?.cancel();

  /// Removes the local copy (and any partial download) of a media id.
  Future<void> deleteLocal(String folder) async {
    _uploadTokens[folder]?.cancel();
    _downloadTokens[folder]?.cancel();
    _local.remove(folder);
    try {
      await store.deleteFolder(folder);
    } catch (_) {}
    notifyListeners();
  }

  Future<String?> pathOf(MediaInfo info) => store.pathOf(info.id, info.name);
  Future<Uint8List?> bytesOf(MediaInfo info) =>
      store.readBytes(info.id, info.name);

  /// Withdraws a finished upload from the relay before its retention ends
  /// (the history transfer target confirmed the import). Best effort.
  Future<void> deleteRemote(String mediaId) => _remote.delete(mediaId);

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
