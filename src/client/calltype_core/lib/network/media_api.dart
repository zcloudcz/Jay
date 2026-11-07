import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';

/// Answer of `POST /media` (encrypted media contract, section 2.1).
class MediaUploadCreated {
  const MediaUploadCreated({
    required this.id,
    required this.chunkSize,
    required this.chunkCount,
    required this.uploadExpiresAt,
  });

  factory MediaUploadCreated.fromJson(Map<String, dynamic> json) =>
      MediaUploadCreated(
        id: json['id'] as String,
        chunkSize: (json['chunkSize'] as num).toInt(),
        chunkCount: (json['chunkCount'] as num).toInt(),
        uploadExpiresAt: DateTime.parse(json['uploadExpiresAt'] as String),
      );

  final String id;

  /// Encrypted chunk size in bytes (plaintext chunk + 16 byte tag).
  final int chunkSize;
  final int chunkCount;
  final DateTime uploadExpiresAt;
}

/// Answer of `GET /media/{id}/upload` (section 2.3), used to resume.
class MediaUploadStatus {
  const MediaUploadStatus({
    required this.id,
    required this.completed,
    required this.chunkCount,
    required this.received,
    required this.uploadExpiresAt,
    this.expiresAt,
  });

  factory MediaUploadStatus.fromJson(Map<String, dynamic> json) =>
      MediaUploadStatus(
        id: json['id'] as String,
        completed: json['status'] == 'completed',
        chunkCount: (json['chunkCount'] as num).toInt(),
        received: {
          for (final i in (json['received'] as List? ?? const []))
            (i as num).toInt(),
        },
        uploadExpiresAt: DateTime.parse(json['uploadExpiresAt'] as String),
        expiresAt: json['expiresAt'] is String
            ? DateTime.parse(json['expiresAt'] as String)
            : null,
      );

  final String id;
  final bool completed;
  final int chunkCount;
  final Set<int> received;
  final DateTime uploadExpiresAt;
  final DateTime? expiresAt;
}

/// A started download: the (possibly ranged) body as a byte stream.
class MediaDownload {
  const MediaDownload({
    required this.stream,
    required this.contentLength,
    required this.partial,
  });

  final Stream<List<int>> stream;

  /// `Content-Length` of THIS response (the remaining bytes for a 206), or
  /// -1 when the server did not say.
  final int contentLength;

  /// True for a 206 answer to a `Range` request.
  final bool partial;
}

/// REST calls of the encrypted media relay (docs/superpowers/specs/
/// 2026-11-07-encrypted-media.md, section 2). The server only ever sees
/// ciphertext: encryption, chunking and the key live in the app.
extension MediaApi on ApiClient {
  /// POST /media with the ENCRYPTED total size and chunk size.
  Future<MediaUploadCreated> createMedia({
    required int size,
    required int chunkSize,
  }) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/media',
      data: {'size': size, 'chunkSize': chunkSize},
    );
    return MediaUploadCreated.fromJson(response.data!);
  }

  /// PUT /media/{id}/chunks/{index}, body = one encrypted chunk. Re-sending
  /// an index replaces it on the server, so a retry is idempotent.
  Future<void> putMediaChunk(
    String id,
    int index,
    Uint8List bytes, {
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    await transport.put<void>(
      '/media/$id/chunks/$index',
      // A stream with an explicit length: dio would otherwise try to
      // JSON-encode a List<int> body.
      data: Stream<List<int>>.value(bytes),
      options: Options(
        contentType: 'application/octet-stream',
        headers: {Headers.contentLengthHeader: bytes.length},
      ),
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );
  }

  /// GET /media/{id}/upload: which chunks the server already holds.
  Future<MediaUploadStatus> getMediaUploadStatus(String id) async {
    final response = await transport.get<Map<String, dynamic>>(
      '/media/$id/upload',
    );
    return MediaUploadStatus.fromJson(response.data!);
  }

  /// POST /media/{id}/complete, returns `expiresAt`. Idempotent.
  Future<DateTime> completeMedia(String id) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/media/$id/complete',
    );
    return DateTime.parse(response.data!['expiresAt'] as String);
  }

  /// DELETE /media/{id} (cancel an upload or withdraw the blob).
  Future<void> deleteMedia(String id) async {
    await transport.delete<void>('/media/$id');
  }

  /// GET /media/{id}, from byte [from] on (a `Range` request when > 0, used
  /// to resume after the chunks already decrypted to disk).
  Future<MediaDownload> downloadMedia(
    String id, {
    int from = 0,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final response = await transport.get<ResponseBody>(
      '/media/$id',
      options: Options(
        responseType: ResponseType.stream,
        headers: {if (from > 0) 'Range': 'bytes=$from-'},
      ),
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
    );
    final body = response.data!;
    final length = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    return MediaDownload(
      stream: body.stream,
      contentLength: length ?? body.contentLength,
      partial: response.statusCode == 206,
    );
  }
}
