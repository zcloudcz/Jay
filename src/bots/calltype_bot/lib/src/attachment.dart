import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_core/media/media_crypto.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:calltype_core/network/media_api.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

/// Largest inline `file` attachment the app sends (its `Attachment.maxBytes`).
const inlineFileMaxBytes = 256 * 1024;

/// Longest inline `file` caption the app sends (`Attachment.maxCaptionLength`
/// counts graphemes; this is a generous bound in UTF-16 units).
const _inlineCaptionMax = 4096;

final _inlineBadName = RegExp(r'[/\\\x00-\x1f]');

/// The server copy of a media file is gone (404 / 410): the 72 h retention
/// passed or the sender withdrew it.
class BotMediaExpired implements Exception {
  const BotMediaExpired();
  @override
  String toString() => 'BotMediaExpired';
}

/// The file is larger than the limit the caller passed.
class BotMediaTooLarge implements Exception {
  const BotMediaTooLarge(this.size, this.limit);
  final int size;
  final int limit;
  @override
  String toString() => 'BotMediaTooLarge: $size bytes, limit $limit';
}

/// Fetches the encrypted blob of a media id (the runtime's [ApiClient]).
typedef MediaFetcher = Future<MediaDownload> Function(String mediaId);

/// A file that came with a message: a voice message, image, audio, video or
/// any file. Either an encrypted media message (contract
/// 2026-11-07-encrypted-media, `media` object, downloaded on demand) or an
/// old inline `file` message (bytes inside the message).
///
/// Nothing is downloaded until [saveTo] or [readBytes] is called (the
/// contract's M8 rule holds for bots too: a bot decides what it fetches).
class BotAttachment {
  BotAttachment._({
    required this.kind,
    required this.name,
    required this.mime,
    required this.size,
    this.caption,
    this.duration,
    this.expiresAt,
    this.width,
    this.height,
    MediaInfo? media,
    Uint8List? inlineBytes,
    MediaFetcher? fetch,
  }) : _media = media,
       _inline = inlineBytes,
       _fetch = fetch;

  /// From a received `media` object; null when it is invalid (the message
  /// then stays plain text with its fallback body, as in the app).
  static BotAttachment? fromMedia(Object? json, MediaFetcher fetch) {
    final info = MediaInfo.tryParse(json);
    if (info == null) return null;
    return BotAttachment._(
      kind: info.kind,
      name: info.name,
      mime: info.mime,
      size: info.size,
      caption: _blankToNull(info.caption),
      duration: info.durationMs == null
          ? null
          : Duration(milliseconds: info.durationMs!),
      expiresAt: info.expiresAt,
      width: info.width,
      height: info.height,
      media: info,
      fetch: fetch,
    );
  }

  /// From the `body` of an inline `type: file` message (`{name, data,
  /// caption?}`, the app's `Attachment.encode`); null when invalid.
  static BotAttachment? fromInlineBody(Object? body) {
    if (body is! String || body.length > inlineFileMaxBytes * 2) return null;
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final name = json['name'];
      final data = json['data'];
      if (name is! String ||
          name.trim().isEmpty ||
          name.length > 255 ||
          name.contains(_inlineBadName) ||
          data is! String) {
        return null;
      }
      final bytes = base64Decode(data);
      if (bytes.length > inlineFileMaxBytes) return null;
      final caption = json['caption'];
      final mime = mediaMimeFor(name);
      return BotAttachment._(
        kind: mediaKindFor(name, mime: mime),
        name: name,
        mime: mime,
        size: bytes.length,
        // A malformed caption is dropped, the file stays (like the app).
        caption: caption is String && caption.length <= _inlineCaptionMax
            ? _blankToNull(caption)
            : null,
        inlineBytes: bytes,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _blankToNull(String? text) {
    final trimmed = text?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// `image`, `video`, `audio`, `voice` or `file`.
  final MediaKind kind;

  /// The sender's file name (validated, safe as a single path segment).
  final String name;

  /// Sender-declared MIME type; untrusted.
  final String mime;

  /// Plaintext bytes.
  final int size;
  final String? caption;

  /// Voice, audio, video: the sender's duration, if given.
  final Duration? duration;

  /// When the server deletes the encrypted copy; null for inline files.
  final DateTime? expiresAt;
  final int? width;
  final int? height;

  final MediaInfo? _media;
  final Uint8List? _inline;
  final MediaFetcher? _fetch;

  /// True for an old inline `file` message (bytes already in the message).
  bool get isInline => _inline != null;

  /// Server media id, null for inline files.
  String? get mediaId => _media?.id;

  bool isExpired(DateTime now) => _media?.isExpired(now) ?? false;

  /// Downloads (if needed), decrypts and verifies the file into [path].
  ///
  /// Streams chunk by chunk with the app's AES-GCM chunk format
  /// (calltype_protocol `MediaCipher`), never holding more than one chunk in
  /// memory, into `<path>.part`; the SHA-256 from the message must match
  /// before the file is renamed to [path]. On any error the partial file
  /// is deleted. Throws [BotMediaTooLarge] (above [maxBytes], before any
  /// request), [BotMediaExpired], `MediaTampered`, `MediaHashMismatch`, or
  /// the network error.
  Future<File> saveTo(String path, {int? maxBytes}) async {
    if (maxBytes != null && size > maxBytes) {
      throw BotMediaTooLarge(size, maxBytes);
    }
    final target = File(path);
    final part = File('$path.part');
    final inline = _inline;
    if (inline != null) {
      await part.writeAsBytes(inline, flush: true);
      return part.rename(path);
    }
    final info = _media!;
    final cipher = MediaCipher(
      key: info.key,
      noncePrefix: info.nonce,
      size: info.size,
      chunkSize: info.chunkSize,
    );
    final sink = part.openWrite();
    var closed = false;
    try {
      final digest = _DigestSink();
      final hash = crypto.sha256.startChunkedConversion(digest);
      final MediaDownload response;
      try {
        response = await _fetch!(info.id);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 404 || status == 410) throw const BotMediaExpired();
        rethrow;
      }
      if (response.contentLength >= 0 &&
          response.contentLength != cipher.encryptedSize) {
        throw const MediaTampered('length');
      }
      await cipher.decryptStream(
        response.stream,
        write: (_, plain) async {
          sink.add(plain);
          hash.add(plain);
        },
      );
      hash.close();
      await sink.flush();
      await sink.close();
      closed = true;
      if (!_sameBytes(digest.value!.bytes, info.sha256)) {
        throw const MediaHashMismatch();
      }
      if (await target.exists()) await target.delete();
      return await part.rename(path);
    } catch (_) {
      if (!closed) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// The plaintext in memory, for small files (images for a vision model).
  /// Same checks as [saveTo]; [maxBytes] is required on purpose.
  Future<Uint8List> readBytes({required int maxBytes}) async {
    if (size > maxBytes) throw BotMediaTooLarge(size, maxBytes);
    final inline = _inline;
    if (inline != null) return inline;
    final dir = await Directory.systemTemp.createTemp('calltype_bot_media');
    try {
      final file = await saveTo('${dir.path}/blob', maxBytes: maxBytes);
      return await file.readAsBytes();
    } finally {
      await dir.delete(recursive: true);
    }
  }

  @override
  String toString() =>
      'BotAttachment(${kind.name}, $name, $mime, $size bytes'
      '${isInline ? ', inline' : ''})';
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
