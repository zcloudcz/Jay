import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/attachment.dart';
import 'package:calltype/features/chat/attachment_media.dart';
import 'package:calltype/features/chat/attachment_sheet.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/image_attachment.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/fake_attachment_media.dart';
import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

/// Photo attachments: the source sheet per platform, inline thumbnails vs
/// the download button, the full-screen viewer with Save / Share, and the
/// pick -> compress -> send path. Platform plugins sit behind
/// [AttachmentMedia], replaced here by [FakeMedia].

class _Transport extends SignalRClient {
  _Transport() : super(baseUrl: 'http://unused', deviceId: 'alice');
  final sent = <Map<String, String>>[];
  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => sent.add(Map.of(encryptedPayloads));
}

class _Api extends ApiClient {
  _Api(this.peers) : super(baseUrl: 'http://unused');
  final List<TestDevice> peers;
  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) =>
      peers.firstWhere((p) => p.id == id).keyBundle();
}

void main() {
  late FakeMedia media;
  late AttachmentMedia original;
  setUp(() {
    original = AttachmentMedia.instance;
    media = FakeMedia();
    AttachmentMedia.instance = media;
  });
  tearDown(() {
    AttachmentMedia.instance = original;
    debugDefaultTargetPlatformOverride = null;
  });

  group('source sheet', () {
    Future<AttachSource?> Function() pumpSheet(WidgetTester tester) {
      AttachSource? picked;
      var done = false;
      return () async {
        await tester.pumpWidget(
          localizedApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    picked = await showAttachSourceSheet(context);
                    done = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(done, isFalse);
        return picked;
      };
    }

    testWidgets('Android with a camera: photo library, camera, file', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpSheet(tester)();
      expect(find.text(l10nEn.chatAttachPhotoLibrary), findsOneWidget);
      expect(find.text(l10nEn.chatAttachCamera), findsOneWidget);
      expect(find.text(l10nEn.chatAttachFile), findsOneWidget);
      expect(find.text(l10nEn.chatAttachPhoto), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('iOS without a camera (simulator): no camera entry', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      media.camera = false;
      await pumpSheet(tester)();
      expect(find.text(l10nEn.chatAttachPhotoLibrary), findsOneWidget);
      expect(find.text(l10nEn.chatAttachCamera), findsNothing);
      expect(find.text(l10nEn.chatAttachFile), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('desktop: photo (file dialog) and file, never the camera', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pumpSheet(tester)();
      expect(find.text(l10nEn.chatAttachPhoto), findsOneWidget);
      expect(find.text(l10nEn.chatAttachFile), findsOneWidget);
      expect(find.text(l10nEn.chatAttachPhotoLibrary), findsNothing);
      expect(find.text(l10nEn.chatAttachCamera), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('chat', () {
    final photo = Attachment(name: 'photo.png', bytes: testPng(60, 40));
    final notes = Attachment(
      name: 'notes.txt',
      bytes: Uint8List.fromList('hello'.codeUnits),
    );
    final broken = Attachment(
      name: 'broken.jpg',
      bytes: Uint8List.fromList(List.filled(64, 7)),
    );

    Future<({_Transport hub, TestDevice alice})> pumpChat(
      WidgetTester tester,
    ) async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = (await tester.runAsync(() => TestDevice.create('alice')))!;
      final peer = (await tester.runAsync(() => TestDevice.create('peer')))!;
      final hub = _Transport();
      late ChatController chat;
      final contacts = ContactsController(database: alice.db);
      await tester.runAsync(() async {
        final db = alice.db;
        await db
            .into(db.conversations)
            .insert(ConversationsCompanion.insert(id: 'peer', type: 'direct'));
        await db
            .into(db.contacts)
            .insert(
              ContactsCompanion.insert(
                deviceId: 'peer',
                userHandle: 'CT-PEER-0001',
                identityKey: Uint8List(0),
                addedAt: DateTime(2026),
              ),
            );
        var minute = 0;
        for (final (id, file) in [
          ('m-photo', photo),
          ('m-notes', notes),
          ('m-broken', broken),
        ]) {
          await db
              .into(db.messages)
              .insert(
                MessagesCompanion.insert(
                  id: id,
                  conversationId: 'peer',
                  senderId: 'peer',
                  body: Value(file.encode()),
                  type: const Value('file'),
                  status: const Value('delivered'),
                  createdAt: DateTime(2026, 1, 1, 10, minute++),
                ),
              );
        }
        await contacts.loadContacts();
        chat = ChatController(
          database: db,
          signalRClient: hub,
          sessionManager: alice.sessions,
          inbox: MessageInboxService(
            database: db,
            sessionManager: alice.sessions,
            directory: () => alice.directory,
            incomingMessages: const Stream.empty(),
          ),
          apiClient: _Api([peer]),
          conversationId: 'peer',
          directory: alice.directory,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      final chats = ChatListController(database: alice.db);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider.value(value: alice.db),
            ChangeNotifierProvider<SignalRClient>.value(value: hub),
            ChangeNotifierProvider.value(value: contacts),
            ChangeNotifierProvider.value(value: chats),
            ChangeNotifierProvider.value(value: chat),
          ],
          child: localizedApp(home: const ChatScreen(contactId: 'peer')),
        ),
      );
      await settle(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        chat.dispose();
        chats.dispose();
        contacts.dispose();
        hub.dispose();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await alice.close();
          await peer.close();
        });
      });
      return (hub: hub, alice: alice);
    }

    String downloadLabel(Attachment a) =>
        l10nEn.chatAttachmentLabel(a.name, l10nEn.sizeBytes(a.bytes.length));

    testWidgets('an image renders inline; a text file and an undecodable '
        '"image" keep the download button', (tester) async {
      await pumpChat(tester);
      expect(find.byType(ImageAttachmentThumbnail), findsNWidgets(2));
      expect(find.text(downloadLabel(photo)), findsNothing);
      expect(find.text(downloadLabel(notes)), findsOneWidget);
      // Image.memory only reports the decode failure after a real decode.
      for (
        var i = 0;
        i < 20 && find.text(downloadLabel(broken)).evaluate().isEmpty;
        i++
      ) {
        await settle(tester);
      }
      expect(find.text(downloadLabel(broken)), findsOneWidget);
      final size = tester.getSize(
        find
            .descendant(
              of: find.byType(ImageAttachmentThumbnail).first,
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(size.width, lessThanOrEqualTo(ImageAttachmentThumbnail.maxWidth));
    });

    testWidgets('tapping the thumbnail opens the viewer; Save goes to the '
        'photo library on mobile and Share hands over the file', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pumpChat(tester);
      await tester.tap(_photoThumbnail);
      await tester.pumpAndSettle();
      expect(find.byType(ImageAttachmentViewer), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip(l10nEn.commonSave));
      await settle(tester);
      expect(media.galleryWrites, ['photo.png']);
      expect(media.fileWrites, isEmpty);
      expect(find.text(l10nEn.chatImageSaved), findsOneWidget);
      await tester.tap(find.byTooltip(l10nEn.commonShare));
      await settle(tester);
      expect(media.shares, ['photo.png']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a refused photo library permission says where to allow it', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      media.denyGallery = true;
      await pumpChat(tester);
      await tester.tap(_photoThumbnail);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10nEn.commonSave));
      await settle(tester);
      expect(find.text(l10nEn.chatImageSaveDenied), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on desktop Save uses the file dialog', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pumpChat(tester);
      await tester.tap(_photoThumbnail);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10nEn.commonSave));
      await settle(tester);
      expect(media.fileWrites, ['photo.png']);
      expect(media.galleryWrites, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'photos from the library are converted to JPEG and each is sent as '
      'its own attachment',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        media.gallery = [
          PickedMedia.bytes('image_picker_1.png', testPng(300, 200)),
          PickedMedia.bytes('image_picker_2.png', testPng(200, 300)),
        ];
        final r = await pumpChat(tester);
        await tester.tap(find.byIcon(Icons.attach_file_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10nEn.chatAttachPhotoLibrary));
        await tester.pump();
        await tester.pump();
        // The progress dialog is up while the photos are prepared.
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        // Compression runs in a real isolate and the send in real DB work:
        // advance both clocks until both messages went out.
        for (var i = 0; i < 200 && r.hub.sent.length < 2; i++) {
          await settle(tester);
        }
        expect(media.calls, ['gallery']);
        expect(r.hub.sent, hasLength(2));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final rows = (await tester.runAsync(
          () => (r.alice.db.select(
            r.alice.db.messages,
          )..where((m) => m.senderId.equals('alice'))).get(),
        ))!;
        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(row.type, 'file');
          final sent = Attachment.decode(row.body!);
          expect(sent.name, matches(RegExp(r'^IMG_\d{8}_\d{6}(_2)?\.jpg$')));
          expect(sent.bytes.sublist(0, 2), [0xFF, 0xD8]);
          expect(sent.bytes.length, lessThanOrEqualTo(Attachment.maxBytes));
        }
        debugDefaultTargetPlatformOverride = null;
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    testWidgets('File keeps the document picker', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pumpChat(tester);
      await tester.tap(find.byIcon(Icons.attach_file_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.chatAttachFile));
      await settle(tester);
      expect(media.calls, ['file']);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

final _photoThumbnail = find.byWidgetPredicate(
  (w) => w is ImageAttachmentThumbnail && w.attachment.name == 'photo.png',
);

/// Lets real async work (isolates, drift, image decoding) advance, then
/// pumps the fake clock.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump(const Duration(milliseconds: 30));
}
