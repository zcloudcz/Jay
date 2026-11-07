import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype/features/media/media_crypto.dart';
import 'package:calltype/features/media/media_message.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype/features/media/media_store_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'media_fakes.dart';

/// Contract section 1: chunked AES-256-GCM, streamed from and to temp files,
/// and every way a blob can be wrong ends as an error with no partial file
/// left behind.
void main() {
  const chunk = mediaMinChunkSize; // 1 MiB: several chunks stay cheap.
  late Directory temp;
  late IoMediaStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jay-media-test');
    store = IoMediaStore(root: () async => Directory('${temp.path}/media'));
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Uint8List plaintext(int size) =>
      Uint8List.fromList(List.generate(size, (i) => (i * 31 + 7) & 0xff));

  /// Encrypts [plain] chunk by chunk into a blob FILE (what the server
  /// stores) and returns the `media` object describing it.
  Future<(MediaInfo, File)> encryptToFile(
    Uint8List plain, {
    String id = '11111111-2222-4333-8444-555555555555',
  }) async {
    final keys = newMediaKey();
    final cipher = MediaCipher(
      key: keys.key,
      noncePrefix: keys.nonce,
      size: plain.length,
      chunkSize: chunk,
    );
    final blob = File('${temp.path}/blob-$id');
    final sink = blob.openWrite();
    for (var i = 0; i < cipher.chunkCount; i++) {
      final start = i * chunk;
      sink.add(
        await cipher.encryptChunk(
          i,
          plain.sublist(
            start,
            start + mediaPlainChunkLength(plain.length, chunk, i),
          ),
        ),
      );
    }
    await sink.close();
    final info = MediaInfo(
      id: id,
      kind: MediaKind.file,
      name: 'data.bin',
      mime: 'application/octet-stream',
      size: plain.length,
      sha256: Uint8List.fromList(crypto.sha256.convert(plain).bytes),
      key: keys.key,
      nonce: keys.nonce,
      chunkSize: chunk,
      expiresAt: DateTime.now().add(const Duration(days: 3)),
    );
    return (info, blob);
  }

  MediaService serviceFor(FakeMediaRemote remote) =>
      MediaService(remote: remote, store: store, web: false);

  Future<bool> partExists(MediaInfo info) =>
      File('${temp.path}/media/${info.id}/${info.name}.part').exists();

  group('round trip from / to temp files', () {
    for (final size in [
      0,
      1,
      chunk - 1,
      chunk,
      2 * chunk,
      chunk * 2 + chunk ~/ 2,
    ]) {
      test('$size bytes', () async {
        final plain = plaintext(size);
        final (info, blob) = await encryptToFile(plain);
        expect(
          await blob.length(),
          mediaEncryptedSize(size, chunk),
          reason: 'size + 16 per chunk',
        );
        final remote = FakeMediaRemote()
          ..blobs[info.id] = await blob.readAsBytes();
        final media = serviceFor(remote);
        await media.download(info);
        expect(media.downloadOf(info.id), isNull);
        final path = await store.pathOf(info.id, info.name);
        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), plain);
        expect(await partExists(info), isFalse);
      });
    }
  });

  group('tampered blobs are rejected and leave no partial file', () {
    final plain = plaintext(chunk * 2 + 100);

    Future<MediaService> run(
      MediaInfo info,
      Uint8List blob, {
      bool withLength = true,
    }) async {
      final remote = FakeMediaRemote()
        ..blobs[info.id] = blob
        ..omitContentLength = !withLength;
      final media = serviceFor(remote);
      await media.download(info);
      return media;
    }

    Future<void> expectDamaged(MediaService media, MediaInfo info) async {
      expect(media.downloadOf(info.id)?.phase, MediaPhase.damaged);
      expect(await store.exists(info.id, info.name), isFalse);
      expect(await partExists(info), isFalse);
    }

    test('truncation: the last chunk dropped', () async {
      final (info, file) = await encryptToFile(plain);
      final blob = await file.readAsBytes();
      final cut = blob.sublist(0, 2 * (chunk + mediaTagLength));
      // Without Content-Length the stream itself must be caught short.
      await expectDamaged(await run(info, cut, withLength: false), info);
      await expectDamaged(await run(info, cut), info);
    });

    test('extension: bytes appended after the last chunk', () async {
      final (info, file) = await encryptToFile(plain);
      final blob = Uint8List.fromList([...await file.readAsBytes(), 1, 2, 3]);
      await expectDamaged(await run(info, blob, withLength: false), info);
    });

    test('two chunks swapped', () async {
      final (info, file) = await encryptToFile(plain);
      final blob = await file.readAsBytes();
      final c = chunk + mediaTagLength;
      final swapped = Uint8List.fromList([
        ...blob.sublist(c, 2 * c),
        ...blob.sublist(0, c),
        ...blob.sublist(2 * c),
      ]);
      await expectDamaged(await run(info, swapped), info);
    });

    test('one flipped bit', () async {
      final (info, file) = await encryptToFile(plain);
      final blob = await file.readAsBytes();
      blob[chunk + 40] ^= 0x01;
      await expectDamaged(await run(info, blob), info);
    });

    test('a wrong key', () async {
      final (info, file) = await encryptToFile(plain);
      final wrong = info.copyWith(key: newMediaKey().key);
      await expectDamaged(await run(wrong, await file.readAsBytes()), wrong);
    });

    test('every chunk verifies but the SHA-256 differs', () async {
      final (info, file) = await encryptToFile(plain);
      final lying = MediaInfo.tryParse({
        ...info.toJson(),
        'sha256': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      })!;
      await expectDamaged(await run(lying, await file.readAsBytes()), lying);
    });

    test('the final flag: a one-chunk prefix of a longer blob', () async {
      // Chunk 0 of a 2-chunk file was sealed with final = 0; claiming the
      // file is only that chunk makes the receiver expect final = 1.
      final (info, file) = await encryptToFile(plain);
      final blob = (await file.readAsBytes()).sublist(
        0,
        chunk + mediaTagLength,
      );
      final short = MediaInfo.tryParse({...info.toJson(), 'size': chunk})!;
      await expectDamaged(await run(short, blob), short);
    });
  });

  test('a network error keeps the verified chunks and the next tap resumes '
      'with a Range request', () async {
    final plain = plaintext(chunk * 3);
    final (info, file) = await encryptToFile(plain);
    final remote = FakeMediaRemote()
      ..blobs[info.id] = await file.readAsBytes()
      ..failAfterBytes = 2 * (chunk + mediaTagLength) + 10;
    final media = serviceFor(remote);
    await media.download(info);
    expect(media.downloadOf(info.id)?.phase, MediaPhase.failed);
    expect(await partExists(info), isTrue);
    remote.failAfterBytes = null;
    await media.download(info);
    expect(remote.downloadFrom.last, 2 * (chunk + mediaTagLength));
    expect(
      await File((await store.pathOf(info.id, info.name))!).readAsBytes(),
      plain,
    );
  });

  test('404 / 410 means expired', () async {
    final (info, _) = await encryptToFile(plaintext(10));
    final media = serviceFor(FakeMediaRemote());
    await media.download(info);
    expect(media.downloadOf(info.id)?.phase, MediaPhase.expired);
  });

  group('upload', () {
    Future<(MediaService, FakeMediaRemote, MediaInfo)> prepare(
      Uint8List plain,
    ) async {
      final remote = FakeMediaRemote();
      final media = serviceFor(remote);
      final stored = await media.importForUpload(
        'msg',
        'clip.mp4',
        Stream.fromIterable([plain]),
      );
      final keys = newMediaKey();
      final draft = MediaInfo(
        id: '',
        kind: MediaKind.video,
        name: 'clip.mp4',
        mime: 'video/mp4',
        size: stored.size,
        sha256: stored.sha256,
        key: keys.key,
        nonce: keys.nonce,
        chunkSize: chunk,
      );
      return (media, remote, draft);
    }

    test('encrypts every chunk, completes, and the blob decrypts', () async {
      final plain = plaintext(chunk * 2 + 5);
      final (media, remote, draft) = await prepare(plain);
      final persisted = <String>[];
      final done = await media.upload(
        'msg',
        draft,
        folder: MediaService.uploadFolder('msg'),
        persist: (info, folder) async => persisted.add(folder),
      );
      expect(done.id, isNotEmpty);
      expect(done.expiresAt, isNotNull);
      expect(remote.created.single, (
        size: mediaEncryptedSize(plain.length, chunk),
        chunkSize: chunk + mediaTagLength,
      ));
      expect(
        remote.blobs[done.id]!.length,
        mediaEncryptedSize(plain.length, chunk),
      );
      // The local copy moved to its final folder (= the media id).
      expect(persisted.last, done.id);
      expect(await store.exists(done.id, 'clip.mp4'), isTrue);
      // A second device can download and verify what was uploaded.
      final other = await Directory.systemTemp.createTemp('jay-media-b');
      addTearDown(() => other.delete(recursive: true));
      final receiver = MediaService(
        remote: remote,
        store: IoMediaStore(root: () async => other),
        web: false,
      );
      await receiver.download(done);
      expect(
        await File('${other.path}/${done.id}/clip.mp4').readAsBytes(),
        plain,
      );
    });

    test('resume sends only the chunks the server is missing', () async {
      final plain = plaintext(chunk * 3);
      final (media, remote, draft) = await prepare(plain);
      remote.failPutAt = 2;
      MediaInfo? saved;
      await expectLater(
        media.upload(
          'msg',
          draft,
          folder: MediaService.uploadFolder('msg'),
          persist: (info, folder) async => saved = info,
        ),
        throwsA(anything),
      );
      expect(saved!.isDraft, isFalse);
      remote.failPutAt = null;
      remote.puts.clear();
      final done = await media.upload(
        'msg',
        saved!,
        folder: saved!.id,
        persist: (info, folder) async {},
      );
      expect(remote.puts, isNot(contains(0)));
      expect(remote.puts, contains(2));
      expect(done.id, saved!.id);
      expect(remote.created, hasLength(1));
    });

    test('an expired upload window starts over with a NEW key', () async {
      final (media, remote, draft) = await prepare(plaintext(100));
      final stale = draft.copyWith(id: '99999999-2222-4333-8444-555555555555');
      await store.renameFolder(MediaService.uploadFolder('msg'), stale.id);
      final done = await media.upload(
        'msg',
        stale,
        folder: stale.id,
        persist: (info, folder) async {},
      );
      expect(done.id, isNot(stale.id));
      expect(done.key, isNot(stale.key));
      expect(remote.created, hasLength(1));
    });

    test('cancel withdraws the blob', () async {
      final (media, remote, draft) = await prepare(plaintext(chunk * 2));
      final gate = Completer<void>();
      remote.putGate = gate.future;
      final upload = media.upload(
        'msg',
        draft,
        folder: MediaService.uploadFolder('msg'),
        persist: (info, folder) async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(media.isUploading('msg'), isTrue);
      media.cancelUpload('msg');
      gate.complete();
      await expectLater(upload, throwsA(isA<MediaCancelled>()));
      expect(remote.deleted, hasLength(1));
      expect(media.uploadOf('msg'), isNull);
    });
  });
}
