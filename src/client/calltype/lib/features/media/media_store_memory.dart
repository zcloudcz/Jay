import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'media_store.dart';

/// Keeps media in memory: the web store (contract M13, session only) and a
/// test double. The web cap (512 MiB) bounds what one file can cost.
class MemoryMediaStore implements MediaStore {
  final _files = <String, Uint8List>{};
  final _parts = <String, BytesBuilder>{};

  String _key(String folder, String name) => '$folder/$name';

  @override
  bool get persistent => false;

  @override
  Future<String?> pathOf(String folder, String name) async => null;

  @override
  Future<bool> exists(String folder, String name) async =>
      _files.containsKey(_key(folder, name));

  /// Direct access for web playback and tests.
  Uint8List? bytesOf(String folder, String name) => _files[_key(folder, name)];

  void put(String folder, String name, Uint8List bytes) =>
      _files[_key(folder, name)] = bytes;

  @override
  Future<StoredMedia> import(
    String folder,
    String name,
    Stream<List<int>> source, {
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    final digest = _DigestSink();
    final hash = crypto.sha256.startChunkedConversion(digest);
    await for (final data in source) {
      if (builder.length + data.length > maxBytes) {
        throw MediaTooLarge(maxBytes);
      }
      builder.add(data);
      hash.add(data);
    }
    hash.close();
    final bytes = builder.takeBytes();
    _files[_key(folder, name)] = bytes;
    return StoredMedia(
      size: bytes.length,
      sha256: Uint8List.fromList(digest.value!.bytes),
    );
  }

  @override
  Future<MediaReader> openReader(String folder, String name) async {
    final bytes = _files[_key(folder, name)];
    if (bytes == null) throw StateError('missing $folder/$name');
    return _MemoryReader(bytes);
  }

  @override
  Future<Stream<List<int>>> openRead(String folder, String name) async {
    final bytes = _files[_key(folder, name)];
    if (bytes == null) throw StateError('missing $folder/$name');
    return Stream.value(bytes);
  }

  @override
  Future<Uint8List?> readBytes(String folder, String name) async =>
      _files[_key(folder, name)];

  @override
  Future<MediaPartWriter> openPart(String folder, String name) async =>
      _MemoryPart(this, _key(folder, name));

  @override
  Future<void> renameFolder(String from, String to) async {
    for (final key in _files.keys.toList()) {
      if (key.startsWith('$from/')) {
        _files['$to/${key.substring(from.length + 1)}'] = _files.remove(key)!;
      }
    }
  }

  @override
  Future<void> deleteFolder(String folder) async {
    _files.removeWhere((key, _) => key.startsWith('$folder/'));
    _parts.removeWhere((key, _) => key.startsWith('$folder/'));
  }
}

class _MemoryReader implements MediaReader {
  _MemoryReader(this._bytes);
  final Uint8List _bytes;
  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(_bytes, offset, offset + length);
  @override
  Future<void> close() async {}
}

class _MemoryPart implements MediaPartWriter {
  _MemoryPart(this._store, this._key)
    : _builder = _store._parts[_key] ??= BytesBuilder(copy: false);
  final MemoryMediaStore _store;
  final String _key;
  BytesBuilder _builder;

  @override
  int get existingLength => _builder.length;

  @override
  Stream<List<int>> readExisting() => Stream.value(_builder.toBytes());

  @override
  Future<void> truncate(int length) async {
    final bytes = _builder.toBytes();
    _builder = _store._parts[_key] = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(bytes, 0, length));
  }

  @override
  Future<void> append(Uint8List bytes) async => _builder.add(bytes);

  @override
  Future<void> commit() async {
    _store._files[_key] = _builder.takeBytes();
    _store._parts.remove(_key);
  }

  @override
  Future<void> discard() async => _store._parts.remove(_key);

  @override
  Future<void> close() async {}
}

/// Collects the single digest of a chunked SHA-256 conversion.
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
