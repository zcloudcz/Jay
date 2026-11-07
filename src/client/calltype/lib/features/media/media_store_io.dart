import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

import 'media_store.dart';

MediaStore createMediaStore() => IoMediaStore();

/// Media files on disk under `<applicationSupport>/media` (contract M9).
/// Everything streams: a 5 GB video is never read into memory.
class IoMediaStore implements MediaStore {
  /// [root] is injected by tests (a temp dir); the app uses the platform's
  /// application support directory, which is app-private and not backed up
  /// to the user's documents.
  IoMediaStore({Future<Directory> Function()? root})
    : _root = root ?? _defaultRoot;

  static Future<Directory> _defaultRoot() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/media');

  final Future<Directory> Function() _root;
  Directory? _resolved;

  Future<Directory> get _base async => _resolved ??= await _root();

  Future<File> _file(String folder, String name) async {
    _checkSegment(folder);
    _checkSegment(name);
    return File('${(await _base).path}/$folder/$name');
  }

  /// Names come from received messages: never let one escape the folder.
  static void _checkSegment(String segment) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains(r'\')) {
      throw ArgumentError('invalid media path segment');
    }
  }

  @override
  bool get persistent => true;

  @override
  Future<String?> pathOf(String folder, String name) async {
    final file = await _file(folder, name);
    return await file.exists() ? file.path : null;
  }

  @override
  Future<bool> exists(String folder, String name) async =>
      (await _file(folder, name)).exists();

  @override
  Future<StoredMedia> import(
    String folder,
    String name,
    Stream<List<int>> source, {
    required int maxBytes,
  }) async {
    final file = await _file(folder, name);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.import');
    final sink = tmp.openWrite();
    final digest = _DigestSink();
    final hash = crypto.sha256.startChunkedConversion(digest);
    var size = 0;
    try {
      await for (final data in source) {
        size += data.length;
        if (size > maxBytes) throw MediaTooLarge(maxBytes);
        hash.add(data);
        sink.add(data);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    hash.close();
    await tmp.rename(file.path);
    return StoredMedia(
      size: size,
      sha256: Uint8List.fromList(digest.value!.bytes),
    );
  }

  @override
  Future<MediaReader> openReader(String folder, String name) async =>
      _IoReader(await (await _file(folder, name)).open());

  @override
  Future<Stream<List<int>>> openRead(String folder, String name) async =>
      (await _file(folder, name)).openRead();

  @override
  Future<Uint8List?> readBytes(String folder, String name) async {
    final file = await _file(folder, name);
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<MediaPartWriter> openPart(String folder, String name) async {
    final file = await _file(folder, name);
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    final raf = await part.open(mode: FileMode.append);
    return _IoPart(file, part, raf, await raf.length());
  }

  @override
  Future<void> renameFolder(String from, String to) async {
    _checkSegment(from);
    _checkSegment(to);
    final base = await _base;
    final source = Directory('${base.path}/$from');
    if (!await source.exists()) return;
    final target = Directory('${base.path}/$to');
    if (await target.exists()) await target.delete(recursive: true);
    await source.rename(target.path);
  }

  @override
  Future<void> deleteFolder(String folder) async {
    _checkSegment(folder);
    final dir = Directory('${(await _base).path}/$folder');
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

class _IoReader implements MediaReader {
  _IoReader(this._raf);
  final RandomAccessFile _raf;

  // RandomAccessFile allows one operation at a time; the uploader runs two
  // chunks concurrently, so reads are serialized here.
  Future<void> _tail = Future.value();

  @override
  Future<Uint8List> read(int offset, int length) {
    final result = _tail.then((_) async {
      await _raf.setPosition(offset);
      return _raf.read(length);
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<void> close() => _tail.then((_) => _raf.close());
}

class _IoPart implements MediaPartWriter {
  _IoPart(this._file, this._part, this._raf, this.existingLength);
  final File _file;
  final File _part;
  final RandomAccessFile _raf;
  bool _closed = false;

  @override
  int existingLength;

  @override
  Stream<List<int>> readExisting() => _part.openRead(0, existingLength);

  @override
  Future<void> truncate(int length) async {
    await _raf.truncate(length);
    await _raf.setPosition(length);
    existingLength = length;
  }

  @override
  Future<void> append(Uint8List bytes) async {
    await _raf.writeFrom(bytes);
  }

  @override
  Future<void> commit() async {
    await close();
    if (await _file.exists()) await _file.delete();
    await _part.rename(_file.path);
  }

  @override
  Future<void> discard() async {
    await close();
    if (await _part.exists()) await _part.delete();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.flush();
    await _raf.close();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
