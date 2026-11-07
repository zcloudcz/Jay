import 'dart:async';
import 'dart:typed_data';

import 'package:calltype/features/media/media_bubble.dart';
import 'package:calltype/features/media/media_message.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype/features/media/media_store_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';
import 'media_fakes.dart';

/// Contract 4.3 / M8: the bubble of a received media message. Nothing is
/// downloaded without a tap on Download; every state shows what it should.
void main() {
  late FakeMediaRemote remote;
  late MemoryMediaStore store;

  setUp(() {
    remote = FakeMediaRemote();
    store = MemoryMediaStore();
  });

  Future<MediaService> pump(
    WidgetTester tester,
    MediaInfo info, {
    bool web = false,
    DateTime Function()? now,
  }) async {
    final media = MediaService(remote: remote, store: store, web: web);
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: Center(
            child: MediaMessageContent(
              messageId: 'm1',
              info: info,
              media: media,
              sending: false,
              now: now ?? () => DateTime.utc(2026, 11, 8),
            ),
          ),
        ),
      ),
    );
    // The local-presence check resolves asynchronously.
    await tester.pump();
    await tester.pump();
    return media;
  }

  Future<(MediaInfo, Uint8List)> encrypted(
    WidgetTester tester,
    int size, {
    MediaKind kind = MediaKind.file,
    String name = 'notes.pdf',
    String mime = 'application/pdf',
    DateTime? expiresAt,
    int? durationMs,
    Uint8List? waveform,
  }) async => (await tester.runAsync(
    () => encryptForTest(
      Uint8List.fromList(List.generate(size, (i) => i & 0xff)),
      kind: kind,
      name: name,
      mime: mime,
      expiresAt: expiresAt,
      durationMs: durationMs,
      waveform: waveform,
    ),
  ))!;

  final download = find.byKey(const ValueKey('media-download'));

  testWidgets('not downloaded: name, size, expiry and a Download button; '
      'no request without a tap', (tester) async {
    final (info, blob) = await encrypted(tester, 2000);
    remote.blobs[info.id] = blob;
    await pump(tester, info);
    expect(find.byKey(const ValueKey('media-notDownloaded')), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.textContaining('Available until'), findsOneWidget);
    expect(download, findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(remote.downloads, 0, reason: 'never automatic (M8)');
  });

  testWidgets('tap: downloading with progress and Cancel, then downloaded '
      'with Open and Save', (tester) async {
    final (info, blob) = await encrypted(tester, 200 * 1000);
    remote
      ..blobs[info.id] = blob
      ..downloadGate = Completer<void>();
    await pump(tester, info);
    await tester.tap(download);
    await tester.pump();
    await tester.pump();
    expect(remote.downloads, 1);
    expect(find.byKey(const ValueKey('media-downloading')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('media-cancel')), findsOneWidget);
    remote.downloadGate!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('media-downloaded')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-save')), findsOneWidget);
    expect(store.bytesOf(info.id, info.name), hasLength(200 * 1000));
  });

  testWidgets('expired: no button, "Media expired"', (tester) async {
    final (info, _) = await encrypted(
      tester,
      10,
      expiresAt: DateTime.utc(2026, 11, 1),
    );
    await pump(tester, info);
    expect(find.byKey(const ValueKey('media-expired')), findsOneWidget);
    expect(find.text(l10nEn.mediaExpired), findsOneWidget);
    expect(download, findsNothing);
  });

  testWidgets('the server copy is gone (404) -> expired', (tester) async {
    final (info, _) = await encrypted(tester, 10);
    await pump(tester, info);
    await tester.tap(download);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10nEn.mediaExpired), findsOneWidget);
  });

  testWidgets('a tampered blob -> "File is damaged" with Retry', (
    tester,
  ) async {
    final (info, blob) = await encrypted(tester, 100);
    blob[5] ^= 1;
    remote.blobs[info.id] = blob;
    await pump(tester, info);
    await tester.tap(download);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text(l10nEn.mediaDamaged), findsOneWidget);
    expect(find.byKey(const ValueKey('media-retry')), findsOneWidget);
    expect(await store.exists(info.id, info.name), isFalse);
  });

  testWidgets('voice before download: waveform and duration from the '
      'message; after download the inline player', (tester) async {
    final (info, blob) = await encrypted(
      tester,
      500,
      kind: MediaKind.voice,
      name: 'voice.m4a',
      mime: 'audio/mp4',
      durationMs: 12000,
      waveform: Uint8List.fromList(List.filled(64, 200)),
    );
    remote.blobs[info.id] = blob;
    await pump(tester, info);
    expect(find.byType(WaveformBars), findsOneWidget);
    expect(find.text('500 B · 0:12'), findsOneWidget);
    expect(find.byType(AudioMessagePlayer), findsNothing);
    await tester.tap(download);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(AudioMessagePlayer), findsOneWidget);
    expect(find.byKey(const ValueKey('media-audio-speed')), findsOneWidget);
    expect(find.text('1×'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('media-audio-speed')));
    await tester.pump();
    expect(find.text('1.5×'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('media-audio-speed')));
    await tester.pump();
    expect(find.text('2×'), findsOneWidget);
  });

  testWidgets('web: a file over 512 MiB says so instead of downloading', (
    tester,
  ) async {
    final (small, _) = await encrypted(tester, 10);
    final huge = MediaInfo.tryParse({
      ...small.toJson(),
      'size': mediaMaxBytesWeb + 1,
    })!;
    await pump(tester, huge, web: true);
    expect(find.text(l10nEn.mediaTooLargeForWeb), findsOneWidget);
    expect(download, findsNothing);
  });

  testWidgets('an own upload shows its progress and Cancel', (tester) async {
    final (info, _) = await encrypted(tester, 10);
    final draft = MediaInfo.tryParse(
      {...info.toJson(), 'id': ''}..remove('expiresAt'),
      draft: true,
    )!;
    final media = MediaService(remote: remote, store: store, web: false);
    var cancelled = 0;
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: MediaMessageContent(
            messageId: 'm1',
            info: draft,
            media: media,
            sending: true,
            onCancelUpload: () => cancelled++,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('media-uploading')), findsOneWidget);
    expect(find.text(l10nEn.mediaUploading(0)), findsOneWidget);
    expect(download, findsNothing);
    expect(cancelled, 0);
  });
}
