import 'dart:convert';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:drift/drift.dart';
import 'package:calltype_core/messaging/contact_sync.dart';

import 'package:calltype_core/storage/database.dart';
import '../contacts/contact_sync.dart';
import '../chat/participant_colors.dart';
import '../chat/polls.dart';
import '../chat/reactions.dart';

/// Imports a backup JSON: insert-or-ignore, so rows already here stay.
///
/// [mergeContacts] (history transfer between own devices, spec
/// 2026-11-08-contact-sync): contacts go through the contact-sync rule
/// instead (last writer wins on the name), so an archive cannot undo a
/// newer rename on this device.
Future<void> importBackup(
  AppDatabase db,
  dynamic input, {
  bool mergeContacts = false,
}) async {
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
          // Older backups have neither key.
          isBot: Value(c['isBot'] == true),
          nameChangedAt: Value(
            c['nameChangedAt'] is int ? c['nameChangedAt'] as int : 0,
          ),
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
      organizationId: Value(
        c['organizationId'] is String ? c['organizationId'] as String : null,
      ),
      organizationName: Value(
        c['organizationName'] is String
            ? c['organizationName'] as String
            : null,
      ),
    );
  }).toList();
  final conversationIds = conversations.map((c) => c.id.value).toSet();
  // 'delete' / 'edit' / 'reaction' rows are transient outbox control messages
  // (deleteForEveryone, editMessage). A backup taken while one was pending
  // must not resurrect it: it has no bubble and would be resent. Skipped, not
  // rejected, so one such row cannot fail a whole restore.
  final messages = rows('messages')
      .where(
        (m) =>
            m['type'] != 'delete' &&
            m['type'] != 'edit' &&
            m['type'] != 'reaction' &&
            m['type'] != 'pin' &&
            m['type'] != pollVoteType,
      )
      .map((m) {
    final conversationId = requiredText(m, 'conversationId');
    if (!conversationIds.contains(conversationId)) {
      throw const FormatException('Missing conversation');
    }
    var type = requiredText(m, 'type');
    final status = requiredText(m, 'status');
    // Spec 2026-11-08-chat-extras: a poll is backed up as text + `poll`
    // (what an older app restores); an invalid object keeps the text.
    var body = m['body'] as String?;
    final poll = type == 'text' ? PollPayload.tryParse(m['poll']) : null;
    if (poll != null) {
      type = pollMessageType;
      body = poll.encode();
    }
    // Every type the app itself writes into `messages` must restore:
    // 'call-event' (business call log) and 'device-change' (multi-device
    // notice) are rows like any other. 'media' rows carry the `media` object
    // (id + key) but not the file: it downloads again while the server copy
    // lives (encrypted media contract M11).
    if (!['text', 'image', 'file', 'audio', 'video', 'media', pollMessageType, 'call-event', 'device-change']
            .contains(type) ||
        !['sending', 'sent', 'delivered', 'read', 'failed'].contains(status)) {
      throw const FormatException('Invalid message type or status');
    }
    return MessagesCompanion.insert(
      id: requiredText(m, 'id'),
      conversationId: conversationId,
      senderId: requiredText(m, 'senderId'),
      body: Value(body),
      type: Value(type),
      status: Value(status == 'sending' ? 'failed' : status),
      createdAt: DateTime.parse(requiredText(m, 'createdAt')),
      receivedAt: Value(date(m['receivedAt'])),
      // Reply/forward/delete fields are absent in backups made before they
      // existed; `is String` / `== true` makes missing or odd values harmless.
      replyToId: Value(
        m['replyToId'] is String ? m['replyToId'] as String : null,
      ),
      replySenderId: Value(
        m['replySenderId'] is String ? m['replySenderId'] as String : null,
      ),
      replyPreview: Value(
        m['replyPreview'] is String ? m['replyPreview'] as String : null,
      ),
      forwarded: Value(m['forwarded'] == true),
      deleted: Value(m['deleted'] == true),
      editedAt: Value(
        m['editedAt'] is String
            ? DateTime.tryParse(m['editedAt'] as String)
            : null,
      ),
      // Re-validated like a received payload: a corrupt value means no
      // buttons, never a failed restore.
      actionsJson: Value(
        m['actionsJson'] is String
            ? encodeActionsJson(decodeActionsJson(m['actionsJson'] as String))
            : null,
      ),
    );
  }).toList();
  // Optional and lenient: a bad reaction row is skipped, never a failed
  // restore (they are decorations of messages, not history).
  final rawReactions = input['reactions'];
  final reactions = <MessageReactionsCompanion>[
    if (rawReactions is List)
      for (final r in rawReactions)
        if (r is Map &&
            r['messageId'] is String &&
            r['reactorId'] is String &&
            r['conversationId'] is String &&
            conversationIds.contains(r['conversationId']) &&
            r['emoji'] is String &&
            (r['emoji'] == '' || isValidReactionEmoji(r['emoji'] as String)) &&
            r['reactedAt'] is int)
          MessageReactionsCompanion.insert(
            messageId: r['messageId'] as String,
            reactorId: r['reactorId'] as String,
            conversationId: r['conversationId'] as String,
            emoji: r['emoji'] as String,
            reactedAt: r['reactedAt'] as int,
          ),
  ];
  // Same leniency for pins and votes (spec 2026-11-08-chat-extras).
  final rawPins = input['pins'];
  final pins = <MessagePinsCompanion>[
    if (rawPins is List)
      for (final p in rawPins)
        if (p is Map &&
            p['conversationId'] is String &&
            conversationIds.contains(p['conversationId']) &&
            p['messageId'] is String &&
            p['pinned'] is bool &&
            p['pinnedBy'] is String &&
            p['changedAt'] is int)
          MessagePinsCompanion.insert(
            conversationId: p['conversationId'] as String,
            messageId: p['messageId'] as String,
            pinned: p['pinned'] as bool,
            pinnedBy: p['pinnedBy'] as String,
            changedAt: p['changedAt'] as int,
          ),
  ];
  final rawVotes = input['pollVotes'];
  final votes = <PollVotesCompanion>[
    if (rawVotes is List)
      for (final v in rawVotes)
        if (v is Map &&
            v['pollId'] is String &&
            v['voterId'] is String &&
            v['conversationId'] is String &&
            conversationIds.contains(v['conversationId']) &&
            v['options'] is List &&
            (v['options'] as List).every((o) => o is int) &&
            validVoteOptions((v['options'] as List).cast<int>()) &&
            v['votedAt'] is int)
          PollVotesCompanion.insert(
            pollId: v['pollId'] as String,
            voterId: v['voterId'] as String,
            conversationId: v['conversationId'] as String,
            options: jsonEncode(
              PollVotePayload(
                pollId: v['pollId'] as String,
                options: (v['options'] as List).cast<int>(),
              ).options,
            ),
            votedAt: v['votedAt'] as int,
          ),
  ];
  // Participant colors (spec 2026-11-09-participant-colors D10): a missing
  // key, an empty person key or an unknown palette index is skipped.
  final rawColors = input['participantColors'];
  final colors = <BackupStateCompanion>[
    if (rawColors is List)
      for (final c in rawColors)
        if (c is Map &&
            c['key'] is String &&
            normalizeParticipantKey(c['key'] as String) != null &&
            c['color'] is int &&
            (c['color'] as int) >= 0 &&
            (c['color'] as int) < participantPalette.length)
          BackupStateCompanion.insert(
            key:
                '$participantColorKeyPrefix'
                '${normalizeParticipantKey(c['key'] as String)}',
            value: '${c['color']}',
          ),
  ];
  await db.transaction(() async {
    if (mergeContacts) {
      // New contacts are inserted below like in a restore; only names of
      // contacts already here are decided by the sync rule.
      final existing = {
        for (final c in await db.select(db.contacts).get()) c.deviceId,
      };
      await applySyncedContacts(db, [
        for (final c in contacts)
          if (existing.contains(c.deviceId.value))
            SyncedContact(
              deviceId: c.deviceId.value,
              userHandle: c.userHandle.value,
              displayName: c.displayName.value,
              isBot: c.isBot.value,
              addedAt: c.addedAt.value,
              nameChangedAt: c.nameChangedAt.value,
            ),
      ]);
    }
    await db.batch((batch) {
      // insertOrIgnore like every other row: a choice made on this device
      // already is newer than the archive's.
      batch.insertAll(db.backupState, colors, mode: InsertMode.insertOrIgnore);
      batch.insertAll(db.messagePins, pins, mode: InsertMode.insertOrIgnore);
      batch.insertAll(db.pollVotes, votes, mode: InsertMode.insertOrIgnore);
      batch.insertAll(
        db.messageReactions,
        reactions,
        mode: InsertMode.insertOrIgnore,
      );
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
