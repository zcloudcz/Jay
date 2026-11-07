import 'dart:typed_data';

import 'media_store_stub.dart'
    if (dart.library.io) 'media_store_io.dart'
    if (dart.library.js_interop) 'media_store_web.dart'
    as platform;

/// Result of copying a picked file into local media storage.
class StoredMedia {
  const StoredMedia({required this.size, required this.sha256});
  final int size;
  final Uint8List sha256;
}

/// Random access to a stored file (the uploader reads chunk i at
/// `i * chunkSize`, several chunks may be in flight at once).
abstract class MediaReader {
  Future<Uint8List> read(int offset, int length);
  Future<void> close();
}

/// A download in progress: plaintext chunks are appended to a `.part`
/// file which is renamed only after the SHA-256 matched.
abstract class MediaPartWriter {
  /// Plaintext bytes already in the `.part` file (resume).
  int get existingLength;

  /// The existing `.part` bytes, to re-hash them before resuming.
  Stream<List<int>> readExisting();
  Future<void> truncate(int length);
  Future<void> append(Uint8List bytes);

  /// Renames `.part` to the final name.
  Future<void> commit();

  /// Deletes the `.part` file (tampering, hash mismatch).
  Future<void> discard();

  /// Closes without deciding (cancel / network error: keep for resume).
  Future<void> close();
}

/// Local media files (contract M9): `<applicationSupport>/media/<folder>/<name>`,
/// where the folder is the server media id (an own upload uses a
/// temporary `up-<messageId>` folder until the server has assigned the id).
/// Decrypted, protected by the app sandbox only (spec Limits). On web the
/// files live in memory for the session (M13).
abstract class MediaStore {
  static MediaStore create() => platform.createMediaStore();

  /// False on web: nothing survives a reload.
  bool get persistent;

  /// Absolute path of a stored file, null when it does not exist (always
  /// null on web, where there are no paths).
  Future<String?> pathOf(String folder, String name);
  Future<bool> exists(String folder, String name);

  /// Streams [source] into the store while hashing it; throws
  /// [MediaTooLarge] (and keeps nothing) past [maxBytes].
  Future<StoredMedia> import(
    String folder,
    String name,
    Stream<List<int>> source, {
    required int maxBytes,
  });

  Future<MediaReader> openReader(String folder, String name);
  Future<Stream<List<int>>> openRead(String folder, String name);

  /// Whole file in memory, for images and web playback only.
  Future<Uint8List?> readBytes(String folder, String name);
  Future<MediaPartWriter> openPart(String folder, String name);
  Future<void> renameFolder(String from, String to);
  Future<void> deleteFolder(String folder);
}

/// The picked file is over the platform cap.
class MediaTooLarge implements Exception {
  const MediaTooLarge(this.maxBytes);
  final int maxBytes;
}

/// Media is not sent in this conversation (business, see
/// `ChatController.sendMedia`).
class MediaNotAllowed implements Exception {
  const MediaNotAllowed();
}
