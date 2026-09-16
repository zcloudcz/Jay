import 'dart:convert';
import 'package:drift/drift.dart';
import '../../core/storage/database.dart';

Future<void> importBackup(AppDatabase db, dynamic input) async {
  if (input is! Map<String, dynamic> || input['version'] != 1) {
    throw const FormatException('Unsupported backup version.');
  }
  String requiredText(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid $key');
    }
    return value;
  }

  List<Map<String, dynamic>> rows(String key) {
    final value = input[key];
    if (value is! List) throw FormatException('Missing $key');
    return value.map((e) {
      if (e is! Map<String, dynamic>) throw FormatException('Invalid $key row');
      return e;
    }).toList();
  }

  DateTime? date(dynamic value) =>
      value == null ? null : DateTime.parse(value as String);
  final contacts = rows('contacts')
      .map(
        (c) => ContactsCompanion.insert(
          deviceId: requiredText(c, 'deviceId'),
          userHandle: requiredText(c, 'userHandle'),
          displayName: Value(c['displayName'] as String?),
          identityKey: base64Decode(c['identityKey'] as String),
          verified: const Value(false),
          addedAt: DateTime.parse(requiredText(c, 'addedAt')),
        ),
      )
      .toList();
  final conversations = rows('conversations').map((c) {
    final type = requiredText(c, 'type');
    if (!['direct', 'group'].contains(type)) {
      throw const FormatException('Invalid conversation type');
    }
    return ConversationsCompanion.insert(
      id: requiredText(c, 'id'),
      type: type,
      title: Value(c['title'] as String?),
      lastMessageAt: Value(date(c['lastMessageAt'])),
      unreadCount: const Value(0),
    );
  }).toList();
  final conversationIds = conversations.map((c) => c.id.value).toSet();
  final messages = rows('messages').map((m) {
    final conversationId = requiredText(m, 'conversationId');
    if (!conversationIds.contains(conversationId)) {
      throw const FormatException('Missing conversation');
    }
    final type = requiredText(m, 'type');
    final status = requiredText(m, 'status');
    if (!['text', 'image', 'file', 'audio', 'video'].contains(type) ||
        !['sending', 'sent', 'delivered', 'read', 'failed'].contains(status)) {
      throw const FormatException('Invalid message type or status');
    }
    return MessagesCompanion.insert(
      id: requiredText(m, 'id'),
      conversationId: conversationId,
      senderId: requiredText(m, 'senderId'),
      body: Value(m['body'] as String?),
      type: Value(type),
      status: Value(status == 'sending' ? 'failed' : status),
      createdAt: DateTime.parse(requiredText(m, 'createdAt')),
      receivedAt: Value(date(m['receivedAt'])),
    );
  }).toList();
  await db.transaction(() async {
    await db.batch((batch) {
      batch.insertAll(db.contacts, contacts, mode: InsertMode.insertOrIgnore);
      batch.insertAll(
        db.conversations,
        conversations,
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(db.messages, messages, mode: InsertMode.insertOrIgnore);
    });
  });
}
