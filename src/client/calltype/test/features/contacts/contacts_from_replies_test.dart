import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/reactions.dart' show reactionType;
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/shared/widgets/bot_badge.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';
import '../chat/chat_controller_test.dart' show Transport;

const _peer = 'a1b2c3d4-0000-4000-8000-000000000001';
const _bot = 'b0b0b0b0-0000-4000-8000-000000000002';

/// `GET /devices/{id}/profile` (spec 2026-11-09-contacts-from-replies C1).
/// [offline] fails like a lost connection; an unknown id answers 404 like an
/// old server or a deleted device.
class ProfileApi extends ApiClient {
  ProfileApi() : super(baseUrl: 'http://unused');
  bool offline = false;
  final calls = <String>[];
  final profiles = <String, Map<String, dynamic>>{
    _peer: {
      'deviceId': _peer,
      'userHandle': 'CT-ALIC-E234',
      'isBot': false,
      'displayName': 'Alice',
    },
    _bot: {
      'deviceId': _bot,
      'userHandle': 'CT-HERM-ES01',
      'isBot': true,
      'displayName': null,
    },
  };

  @override
  Future<Map<String, dynamic>> getDeviceProfile(String deviceId) async {
    calls.add(deviceId);
    final options = RequestOptions(path: '/devices/$deviceId/profile');
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    final profile = profiles[deviceId];
    if (profile == null) {
      throw DioException.badResponse(
        statusCode: 404,
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 404),
      );
    }
    return profile;
  }
}

Future<void> _conversation(
  AppDatabase db,
  String id, {
  String type = 'direct',
  String? organizationId,
  String? title,
}) => db
    .into(db.conversations)
    .insert(
      ConversationsCompanion.insert(
        id: id,
        type: type,
        title: Value(title),
        organizationId: Value(organizationId),
      ),
    );

Future<String> _message(
  AppDatabase db,
  String conversationId, {
  String sender = 'me',
  String type = 'text',
}) async {
  final id = 'm${DateTime.now().microsecondsSinceEpoch}';
  await db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          senderId: sender,
          body: const Value('hi'),
          type: Value(type),
          status: const Value('sending'),
          createdAt: DateTime.now(),
        ),
      );
  return id;
}

void main() {
  late AppDatabase db;
  late ProfileApi api;
  late ContactsController contacts;
  late List<String> synced;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    api = ProfileApi();
    synced = [];
    contacts = ContactsController(
      database: db,
      apiClient: api,
      onLocalChange: (id) async => synced.add(id),
    );
  });

  tearDown(() async {
    contacts.dispose();
    await db.close();
  });

  group('addPeerOnReply (C2)', () {
    test(
      'a reply adds exactly one contact from the profile, synced once',
      () async {
        await _conversation(db, _peer);
        final id = await _message(db, _peer);

        // Two sends racing (e.g. text + retry) share one lookup and add.
        await Future.wait([
          contacts.addPeerOnReply(id),
          contacts.addPeerOnReply(id),
        ]);
        await contacts.addPeerOnReply(await _message(db, _peer));

        final rows = await db.select(db.contacts).get();
        expect(rows, hasLength(1));
        expect(rows.single.deviceId, _peer);
        expect(rows.single.userHandle, 'CT-ALIC-E234');
        expect(rows.single.displayName, 'Alice');
        expect(rows.single.isBot, isFalse);
        expect(contacts.contacts.single.deviceId, _peer);
        expect(api.calls, [_peer]);
        // The contact-sync hook carries the add to my other devices.
        expect(synced, [_peer]);
      },
    );

    test('a bot 1:1 is added like a person, with the bot flag', () async {
      await _conversation(db, _bot);
      await contacts.addPeerOnReply(await _message(db, _bot));

      final row = await db.select(db.contacts).getSingle();
      expect(row.userHandle, 'CT-HERM-ES01');
      expect(row.isBot, isTrue);
      expect(row.displayName, isNull);
    });

    test('an incoming message alone adds nobody', () async {
      await _conversation(db, _peer);
      await contacts.addPeerOnReply(await _message(db, _peer, sender: _peer));

      expect(await db.select(db.contacts).get(), isEmpty);
      expect(api.calls, isEmpty);
    });

    test('groups, business chats and control messages add nobody', () async {
      await _conversation(db, 'group-1', type: 'group', title: 'Team');
      await _conversation(db, _bot, organizationId: 'org-1');
      await _conversation(db, _peer);

      await contacts.addPeerOnReply(await _message(db, 'group-1'));
      await contacts.addPeerOnReply(await _message(db, _bot));
      await contacts.addPeerOnReply(
        await _message(db, _peer, type: reactionType),
      );
      await contacts.addPeerOnReply('no-such-message');

      expect(await db.select(db.contacts).get(), isEmpty);
      expect(api.calls, isEmpty);
    });

    test(
      'a failed lookup never throws and is retried on the next send',
      () async {
        await _conversation(db, _peer);
        api.offline = true;
        await contacts.addPeerOnReply(await _message(db, _peer));
        expect(await db.select(db.contacts).get(), isEmpty);

        api.offline = false;
        await contacts.addPeerOnReply(await _message(db, _peer));
        expect((await db.select(db.contacts).getSingle()).deviceId, _peer);
        expect(api.calls, [_peer, _peer]);
      },
    );

    test('an existing contact is left alone', () async {
      await _conversation(db, _peer);
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: _peer,
              userHandle: 'CT-ALIC-E234',
              identityKey: Uint8List(0),
              addedAt: DateTime(2026),
              displayName: const Value('My Alice'),
            ),
          );
      await contacts.addPeerOnReply(await _message(db, _peer));

      expect(
        (await db.select(db.contacts).getSingle()).displayName,
        'My Alice',
      );
      expect(api.calls, isEmpty);
      expect(synced, isEmpty);
    });
  });

  group('ensureContact (C3/C5)', () {
    test(
      'an unknown device (old server, 404) throws and adds nothing',
      () async {
        await expectLater(
          contacts.ensureContact('c0c0c0c0-0000-4000-8000-000000000003'),
          throwsA(isA<DioException>()),
        );
        expect(await db.select(db.contacts).get(), isEmpty);
      },
    );

    test('a profile for another device id is rejected', () async {
      api.profiles[_peer] = {...api.profiles[_peer]!, 'deviceId': _bot};
      await expectLater(
        contacts.ensureContact(_peer),
        throwsA(isA<FormatException>()),
      );
      expect(await db.select(db.contacts).get(), isEmpty);
    });
  });

  group('peerProfile (C4)', () {
    Future<void> settle() => Future<void>.delayed(
      Duration.zero,
    ).then((_) => Future<void>.delayed(const Duration(milliseconds: 20)));

    test('looks up once, notifies, and caches in backup_state', () async {
      var notified = 0;
      contacts.addListener(() => notified++);

      expect(contacts.peerProfile(_peer), isNull);
      expect(contacts.peerProfile(_peer), isNull);
      await settle();

      expect(contacts.peerProfile(_peer)!.label, 'Alice');
      expect(notified, greaterThan(0));
      expect(api.calls, [_peer]);
      final row = await db.select(db.backupState).getSingle();
      expect(row.key, '${ContactsController.peerProfileKeyPrefix}$_peer');

      // Another controller (app restart) reads the cache without a lookup.
      final restarted = ContactsController(database: db, apiClient: api);
      restarted.peerProfile(_peer);
      await settle();
      expect(restarted.peerProfile(_peer)!.label, 'Alice');
      expect(api.calls, [_peer]);
      restarted.dispose();
    });

    test('no display name: the handle is the label', () async {
      contacts.peerProfile(_bot);
      await settle();
      expect(contacts.peerProfile(_bot)!.label, 'CT-HERM-ES01');
      expect(contacts.peerProfile(_bot)!.isBot, isTrue);
    });

    test('a cache older than 24 h is fetched again', () async {
      final old = PeerProfile(
        handle: 'CT-ALIC-E234',
        displayName: 'Old name',
        isBot: false,
        fetchedAt: DateTime.now().subtract(const Duration(hours: 25)),
      );
      await db
          .into(db.backupState)
          .insert(
            BackupStateCompanion.insert(
              key: '${ContactsController.peerProfileKeyPrefix}$_peer',
              value: old.encode(),
            ),
          );
      contacts.peerProfile(_peer);
      await settle();
      expect(contacts.peerProfile(_peer)!.label, 'Alice');
      expect(api.calls, [_peer]);
    });

    test('offline: stays null and does not retry on every build', () async {
      api.offline = true;
      contacts.peerProfile(_peer);
      await settle();
      contacts.peerProfile(_peer);
      await settle();
      expect(contacts.peerProfile(_peer), isNull);
      expect(api.calls, [_peer]);
    });
  });

  test(
    'the send path: a failed lookup still sends, the next send adds',
    () async {
      final alice = await TestDevice.create('me');
      final peer = await TestDevice.create(_peer);
      final transport = Transport()..fail = false;
      final peerApi = _ChatProfileApi(peer, api);
      final replyContacts = ContactsController(
        database: alice.db,
        apiClient: peerApi,
        onLocalChange: (id) async => synced.add(id),
      );
      await _conversation(alice.db, _peer);
      final hooked = <String>[];
      final chat = ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: MessageInboxService(
          database: alice.db,
          sessionManager: alice.sessions,
          directory: () => alice.directory,
          incomingMessages: const Stream.empty(),
        ),
        apiClient: peerApi,
        conversationId: _peer,
        directory: alice.directory,
        onOwnSend: (id) {
          hooked.add(id);
          replyContacts.addPeerOnReply(id);
        },
      );

      api.offline = true;
      await chat.sendMessage('first reply');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final first = await alice.db.select(alice.db.messages).getSingle();
      expect(first.status, 'sent');
      expect(hooked, [first.id]);
      expect(await alice.db.select(alice.db.contacts).get(), isEmpty);

      api.offline = false;
      await chat.sendMessage('second reply');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final contact = await alice.db.select(alice.db.contacts).getSingle();
      expect(contact.userHandle, 'CT-ALIC-E234');
      expect(synced, [_peer]);

      chat.dispose();
      replyContacts.dispose();
      await alice.db.close();
      await peer.db.close();
    },
  );

  group('chat menu and title (C3/C4)', () {
    /// Teardown order as in bot_badge_test: widgets, controllers, fake-clock
    /// timers, then the database.
    Future<Future<void> Function()> pumpChat(
      WidgetTester tester, {
      String id = _peer,
    }) async {
      final signal = SignalRClient(baseUrl: 'http://unused', deviceId: 'me');
      final keys = KeyManager(secureStorage: InMemorySecureStorage());
      final sessions = SessionManager(
        store: DriftProtocolStore(db),
        keyManager: keys,
      );
      final directory = DeviceDirectory(
        database: db,
        apiClient: NoDeviceListsApi(),
        selfDeviceId: 'me',
        selfSigningKey: () async =>
            (await keys.getSignedIdentityBundle())['signingKey']!,
        selfIdentityKey: keys.getPublicIdentityKey,
      );
      final chats = ChatListController(database: db);
      late ChatController chat;
      await tester.runAsync(() async {
        await _conversation(db, id);
        await chats.loadConversations();
        chat = ChatController(
          database: db,
          signalRClient: signal,
          sessionManager: sessions,
          inbox: MessageInboxService(
            database: db,
            sessionManager: sessions,
            directory: () => directory,
            incomingMessages: const Stream.empty(),
          ),
          apiClient: ApiClient(baseUrl: 'http://unused'),
          conversationId: id,
          directory: directory,
        );
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider.value(value: db),
            ChangeNotifierProvider.value(value: signal),
            ChangeNotifierProvider.value(value: contacts),
            ChangeNotifierProvider.value(value: chats),
            ChangeNotifierProvider.value(value: chat),
          ],
          child: localizedApp(home: ChatScreen(contactId: id)),
        ),
      );
      await settle(tester);
      return () async {
        await tester.pumpWidget(const SizedBox());
        chat.dispose();
        chats.dispose();
        signal.dispose();
        await tester.pump(const Duration(seconds: 1));
      };
    }

    testWidgets('title is the profile name, not the device id', (tester) async {
      final cleanUp = await pumpChat(tester);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text(_peer), findsNothing);
      await cleanUp();
    });

    testWidgets('a bot non-contact: handle title and BOT badge', (
      tester,
    ) async {
      final cleanUp = await pumpChat(tester, id: _bot);
      expect(find.text('CT-HERM-ES01'), findsOneWidget);
      expect(find.byType(BotBadge), findsOneWidget);
      await cleanUp();
    });

    testWidgets('Rename for a non-contact adds it, then renames', (
      tester,
    ) async {
      final cleanUp = await pumpChat(tester);
      await tester.tap(find.byKey(const ValueKey('chat-direct-menu')));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.contactsAddContact), findsOneWidget);
      await tester.tap(find.text(l10nEn.contactRename));
      await settle(tester);
      await tester.pumpAndSettle();

      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      expect(find.text('CT-ALIC-E234'), findsOneWidget); // helper text
      await tester.enterText(field, 'Ali');
      await tester.tap(find.text(l10nEn.commonSave));
      await settle(tester);
      await tester.pumpAndSettle();

      final row = (await tester.runAsync(
        () => db.select(db.contacts).getSingle(),
      ))!;
      expect(row.displayName, 'Ali');
      expect(row.userHandle, 'CT-ALIC-E234');
      expect(find.text('Ali'), findsOneWidget);
      // Add, then rename: both go to my other devices.
      expect(synced, [_peer, _peer]);

      // Now a contact: the menu offers Rename only.
      await tester.tap(find.byKey(const ValueKey('chat-direct-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-add-contact')), findsNothing);
      expect(find.byKey(const ValueKey('chat-rename')), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await cleanUp();
    });

    testWidgets('Add contact adds without a dialog', (tester) async {
      final cleanUp = await pumpChat(tester);
      await tester.tap(find.byKey(const ValueKey('chat-direct-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-add-contact')));
      await settle(tester);
      await tester.pump();

      expect(find.text(l10nEn.contactsAdded('CT-ALIC-E234')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      final row = (await tester.runAsync(
        () => db.select(db.contacts).getSingle(),
      ))!;
      expect(row.displayName, 'Alice');
      await tester.pump(const Duration(seconds: 5));
      await cleanUp();
    });

    testWidgets('offline: Rename shows the error and adds nothing', (
      tester,
    ) async {
      api.offline = true;
      final cleanUp = await pumpChat(tester);
      expect(find.text(_peer), findsOneWidget); // no profile, no name yet
      await tester.tap(find.byKey(const ValueKey('chat-direct-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-rename')));
      await settle(tester);
      await tester.pump();

      expect(find.text(l10nEn.contactsAddFromChatFailed), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        await tester.runAsync(() => db.select(db.contacts).get()),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 5));
      await cleanUp();
    });
  });
}

/// Lets real database work and the fake clock advance together.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// Key bundles for the 1:1 send plus the profile answers of [profiles].
class _ChatProfileApi extends ApiClient {
  _ChatProfileApi(this.peer, this.profiles) : super(baseUrl: 'http://unused');
  final TestDevice peer;
  final ProfileApi profiles;

  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) => peer.keyBundle();

  @override
  Future<Map<String, dynamic>> getDeviceProfile(String deviceId) =>
      profiles.getDeviceProfile(deviceId);
}
