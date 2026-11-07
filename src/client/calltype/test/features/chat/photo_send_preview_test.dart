import 'package:calltype/features/chat/attachment_sheet.dart';
import 'package:calltype/features/chat/photo_send_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_attachment_media.dart';
import '../../helpers/localized_app.dart';

/// The review screen between picking photos and sending them.
void main() {
  final photos = [
    for (final name in ['IMG_a.jpg', 'IMG_b.jpg', 'IMG_c.jpg'])
      PreparedPhoto(name: name, bytes: testPng(40, 30), decoded: true),
  ];

  Future<PhotoSendResult? Function()> open(
    WidgetTester tester,
    List<PreparedPhoto> photos,
  ) async {
    PhotoSendResult? result;
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showPhotoSendPreview(context, photos),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Finder remove(String name) => find.descendant(
    of: find.byKey(ValueKey('photo-preview-$name')),
    matching: find.byTooltip(l10nEn.chatPhotoPreviewRemove),
  );

  testWidgets('remove one photo, add a caption, send', (tester) async {
    final result = await open(tester, photos);
    expect(find.text(l10nEn.chatPhotoPreviewTitle(3)), findsOneWidget);
    await tester.tap(remove('IMG_b.jpg'));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatPhotoPreviewTitle(2)), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-preview-IMG_b.jpg')), findsNothing);
    await tester.enterText(find.byType(TextField), '  Holiday  ');
    await tester.tap(find.byTooltip(l10nEn.chatInputSend));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoSendPreview), findsNothing);
    expect(result()!.photos.map((p) => p.name), ['IMG_a.jpg', 'IMG_c.jpg']);
    expect(result()!.caption, 'Holiday');
  });

  testWidgets('no caption is null, not an empty string', (tester) async {
    final result = await open(tester, photos.take(1).toList());
    expect(find.text(l10nEn.chatPhotoPreviewTitle(1)), findsOneWidget);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byTooltip(l10nEn.chatInputSend));
    await tester.pumpAndSettle();
    expect(result()!.photos, hasLength(1));
    expect(result()!.caption, isNull);
  });

  testWidgets('cancel returns nothing', (tester) async {
    final result = await open(tester, photos);
    await tester.tap(find.byTooltip(l10nEn.commonCancel));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoSendPreview), findsNothing);
    expect(result(), isNull);
  });

  testWidgets('removing the last photo is a cancel', (tester) async {
    final result = await open(tester, photos.take(1).toList());
    await tester.tap(remove('IMG_a.jpg'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoSendPreview), findsNothing);
    expect(result(), isNull);
  });

  testWidgets('tapping a thumbnail shows that photo large', (tester) async {
    await open(tester, photos);
    expect(find.byKey(const ValueKey('photo-preview-large-0')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('photo-preview-IMG_c.jpg')),
        matching: find.byType(Image),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('photo-preview-large-2')), findsOneWidget);
  });
}
