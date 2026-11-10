import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_core/media/media_crypto.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/channel_dtos.dart' show parseErrorCode;
import 'package:calltype_core/network/media_api.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

import 'attachment.dart' show BotMediaTooLarge;

/// The server refused an upload (4xx): too large (`media_too_large`), a
/// quota (`media_quota_exceeded`, `media_rate_limited`), storage full
/// (`media_storage_full`, 503) and the like. Not worth retrying as is.
class BotMediaRefused implements Exception {
  const BotMediaRefused(this.statusCode, this.code);
  final int statusCode;
  final String? code;
  @override
  String toString() => 'BotMediaRefused: HTTP $statusCode ${code ?? ''}'.trim();
}

/// Encrypts [file] with the app's chunk format (calltype_core
/// [MediaCipher], a fresh key per file) and uploads it through the media
/// relay (contract 2026-11-07-encrypted-media, sections 1 and 2):
/// `POST /media`, one `PUT /media/{id}/chunks/{i}` per 4 MiB chunk, then
/// `POST /media/{id}/complete`. Reads the file chunk by chunk (never the
/// whole file in memory) and hashes the plaintext on the way.
///
/// Returns the finished `media` object (with id, sha256 and expiry). On a
/// failure after `POST /media` the upload is withdrawn (`DELETE`, best
/// effort). Throws [BotMediaTooLarge] above [maxBytes] (before any
/// request), [BotMediaRefused] for a 4xx/503 answer, or the network error.
Future<MediaInfo> uploadMediaFile(
  ApiClient api,
  File file, {
  required MediaKind kind,
  required String name,
  required String mime,
  int maxBytes = mediaMaxBytes,
  int chunkSize = mediaChunkSize,
  int? durationMs,
  int? width,
  int? height,
  Uint8List? thumbnail,
  Uint8List? waveform,
  String? caption,
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final size = await file.length();
  if (size > maxBytes) throw BotMediaTooLarge(size, maxBytes);
  final keys = newMediaKey();
  final cipher = MediaCipher(
    key: keys.key,
    noncePrefix: keys.nonce,
    size: size,
    chunkSize: chunkSize,
  );
  final MediaUploadCreated created;
  try {
    created = await api.createMedia(
      size: cipher.encryptedSize,
      chunkSize: cipher.encryptedChunkSize,
    );
  } on DioException catch (e) {
    throw _refusal(e) ?? e;
  }
  final reader = await file.open();
  try {
    final digest = _DigestSink();
    final hash = crypto.sha256.startChunkedConversion(digest);
    for (var i = 0; i < cipher.chunkCount; i++) {
      final length = mediaPlainChunkLength(size, chunkSize, i);
      final plain = await reader.read(length);
      if (plain.length != length) {
        throw FileSystemException('file changed while sending', file.path);
      }
      hash.add(plain);
      final sealed = await cipher.encryptChunk(i, plain);
      await _withRetry(
        () => api.putMediaChunk(created.id, i, sealed),
        retryDelay,
      );
    }
    if (await reader.length() != size) {
      throw FileSystemException('file changed while sending', file.path);
    }
    hash.close();
    final expiresAt = await _withRetry(
      () => api.completeMedia(created.id),
      retryDelay,
    );
    return MediaInfo(
      id: created.id.toLowerCase(),
      kind: kind,
      name: name,
      mime: mime,
      size: size,
      sha256: Uint8List.fromList(digest.value!.bytes),
      key: keys.key,
      nonce: keys.nonce,
      chunkSize: chunkSize,
      expiresAt: expiresAt,
      durationMs: durationMs,
      width: width,
      height: height,
      thumbnail: thumbnail,
      waveform: waveform,
      caption: caption,
    );
  } catch (e) {
    try {
      await api.deleteMedia(created.id);
    } catch (_) {
      // The server's 24 h upload window cleans up anyway.
    }
    if (e is DioException) throw _refusal(e) ?? e;
    rethrow;
  } finally {
    await reader.close();
  }
}

/// One retry after [delay] (then one more after twice that) on a network
/// error, 5xx or 429. A chunk PUT is idempotent (same key, nonce and index
/// give the same bytes), so is `complete`.
Future<T> _withRetry<T>(Future<T> Function() call, Duration delay) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await call();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final transient = status == null || status >= 500 || status == 429;
      if (!transient || attempt == 3) rethrow;
    }
    await Future<void>.delayed(delay * attempt);
  }
}

BotMediaRefused? _refusal(DioException e) {
  final status = e.response?.statusCode;
  if (status == null) return null;
  if ((status >= 400 && status < 500) || status == 503) {
    return BotMediaRefused(status, parseErrorCode(e.response?.data));
  }
  return null;
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// English fallback body for old clients (the app's `mediaFallbackBody` in
/// its default locale), followed by the caption on its own line.
String mediaFallbackText(MediaInfo info) {
  final duration = info.durationMs;
  final size = formatMediaSize(info.size);
  final what = switch (info.kind) {
    MediaKind.voice when duration != null =>
      '🎤 Voice message (${formatMediaDuration(duration)}). '
          'Update Jay to play it.',
    MediaKind.video => '🎬 Video ($size). Update Jay to play it.',
    MediaKind.image => '🖼 Photo ($size). Update Jay to view it.',
    MediaKind.audio ||
    MediaKind.file ||
    MediaKind.voice => '📎 ${info.name} ($size). Update Jay to download it.',
  };
  final caption = info.caption?.trim();
  return caption == null || caption.isEmpty ? what : '$what\n$caption';
}
