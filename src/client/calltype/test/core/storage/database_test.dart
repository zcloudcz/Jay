
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/storage/database.dart';

/// Tests for the Drift [AppDatabase] using an in-memory SQLite database.
///
/// The AppDatabase.forTesting constructor accepts a custom QueryExecutor,
/// so we pass NativeDatabase.memory() to avoid touching the filesystem
/// and to get a fresh schema on every test run.
void main() {
  late AppDatabase db;

  setUp(() {
    // Each test gets a pristine in-memory database — no cross-test
    // contamination and no cleanup needed.
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('Contacts', () {
    test('insert and query contact', () async {
      final now = DateTime.now();
      final identityKey = Uint8List.fromList(List.filled(32, 0xAB));

      // Insert a contact using the Companion (Drift's insert pattern).
      await db.into(db.contacts).insert(
            ContactsCompanion.insert(
              deviceId: 'device-001',
              userHandle: 'CT-A1B2-C3D4',
              identityKey: identityKey,
              addedAt: now,
            ),
          );

      // Query it back and verify all fields round-trip correctly.
      final contacts = await db.select(db.contacts).get();
      expect(contacts, hasLength(1));

      final contact = contacts.first;
      expect(contact.deviceId, equals('device-001'));
      expect(contact.userHandle, equals('CT-A1B2-C3D4'));
      expect(contact.displayName, isNull);
      expect(contact.identityKey, equals(identityKey));
      // Default value from the table definition.
      expect(contact.verified, isFalse);
    });
  });

  group('Conversations', () {
    test('insert and query conversation', () async {
      await db.into(db.conversations).insert(
            ConversationsCompanion.insert(
              id: 'conv-001',
              type: 'direct',
            ),
          );

      final conversations = await db.select(db.conversations).get();
      expect(conversations, hasLength(1));

      final conv = conversations.first;
      expect(conv.id, equals('conv-001'));
      expect(conv.type, equals('direct'));
      expect(conv.title, isNull);
      expect(conv.lastMessageAt, isNull);
    });

    test('unread count defaults to zero', () async {
      // The schema defines unreadCount with a default of 0. Verify that
      // inserting without specifying it gives us the expected default.
      await db.into(db.conversations).insert(
            ConversationsCompanion.insert(
              id: 'conv-unread',
              type: 'group',
            ),
          );

      final conv = await (db.select(db.conversations)
            ..where((t) => t.id.equals('conv-unread')))
          .getSingle();

      expect(conv.unreadCount, equals(0));
    });
  });

  group('Messages', () {
    test('insert and query message', () async {
      final now = DateTime.now();

      // Insert a parent conversation first (messages reference it).
      await db.into(db.conversations).insert(
            ConversationsCompanion.insert(id: 'conv-msg', type: 'direct'),
          );

      await db.into(db.messages).insert(
            MessagesCompanion.insert(
              id: 'msg-001',
              conversationId: 'conv-msg',
              senderId: 'device-sender',
              createdAt: now,
              body: const Value('Hello, world!'),
            ),
          );

      final messages = await db.select(db.messages).get();
      expect(messages, hasLength(1));

      final msg = messages.first;
      expect(msg.id, equals('msg-001'));
      expect(msg.conversationId, equals('conv-msg'));
      expect(msg.senderId, equals('device-sender'));
      expect(msg.body, equals('Hello, world!'));
      // Default values from the table definition.
      expect(msg.type, equals('text'));
      expect(msg.status, equals('sent'));
    });

    test('messages ordered by createdAt', () async {
      // Insert a conversation to hold the messages.
      await db.into(db.conversations).insert(
            ConversationsCompanion.insert(id: 'conv-order', type: 'direct'),
          );

      final base = DateTime(2026, 6, 1, 12, 0);

      // Insert three messages with different timestamps (out of order).
      await db.into(db.messages).insert(
            MessagesCompanion.insert(
              id: 'msg-second',
              conversationId: 'conv-order',
              senderId: 'sender',
              createdAt: base.add(const Duration(minutes: 1)),
            ),
          );
      await db.into(db.messages).insert(
            MessagesCompanion.insert(
              id: 'msg-first',
              conversationId: 'conv-order',
              senderId: 'sender',
              createdAt: base,
            ),
          );
      await db.into(db.messages).insert(
            MessagesCompanion.insert(
              id: 'msg-third',
              conversationId: 'conv-order',
              senderId: 'sender',
              createdAt: base.add(const Duration(minutes: 2)),
            ),
          );

      // Query with ORDER BY createdAt ascending.
      final ordered = await (db.select(db.messages)
            ..orderBy([
              (t) => OrderingTerm.asc(t.createdAt),
            ]))
          .get();

      expect(ordered.map((m) => m.id).toList(),
          equals(['msg-first', 'msg-second', 'msg-third']));
    });
  });
}
