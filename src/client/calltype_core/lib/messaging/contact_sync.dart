/// Wire format of contact sync between the devices of ONE identity
/// (`type: contact-sync` and `contact-sync-request`), shared by the app and
/// tests (docs/superpowers/specs/2026-11-08-contact-sync.md).
///
/// WHY decoding never throws: the body comes from another device. An invalid
/// message decodes to null (the receiver acks and drops it); an invalid entry
/// inside a valid message is skipped and the rest is applied.
library;

import 'dart:convert';

/// Message payload `type` of a contact upsert, snapshot or removal.
const contactSyncType = 'contact-sync';

/// Message payload `type` of a companion asking for a snapshot; body `{}`.
const contactSyncRequestType = 'contact-sync-request';

/// Most contacts, and separately most conversations, in one message. A
/// larger snapshot is split ([ContactSyncPayload.snapshots]).
const maxContactSyncEntries = 2000;

/// Longest display name after trimming.
const maxSyncedNameLength = 100;

final _guid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _handle = RegExp(r'^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$');

/// One contact row as it travels between own devices. Identity keys,
/// `verified` and sessions are deliberately NOT part of it (spec decisions).
class SyncedContact {
  SyncedContact({
    required this.deviceId,
    required this.userHandle,
    required String? displayName,
    required this.isBot,
    required this.addedAt,
    required this.nameChangedAt,
  }) : displayName = normalizeSyncedName(displayName);

  final String deviceId;
  final String userHandle;

  /// Null = no nickname (the handle is shown). Already trimmed.
  final String? displayName;
  final bool isBot;
  final DateTime addedAt;

  /// ms since epoch on the writer's clock; 0 = never renamed.
  final int nameChangedAt;

  bool get isValid =>
      _guid.hasMatch(deviceId) &&
      _handle.hasMatch(userHandle) &&
      nameChangedAt >= 0 &&
      (displayName == null || displayName!.length <= maxSyncedNameLength);

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'userHandle': userHandle,
    'displayName': displayName,
    'isBot': isBot,
    'addedAt': addedAt.toUtc().toIso8601String(),
    'nameChangedAt': nameChangedAt,
  };

  static SyncedContact? tryParse(Object? json) {
    if (json is! Map) return null;
    final deviceId = json['deviceId'];
    final userHandle = json['userHandle'];
    final displayName = json['displayName'];
    final isBot = json['isBot'];
    final addedAt = json['addedAt'];
    final nameChangedAt = json['nameChangedAt'];
    if (deviceId is! String ||
        userHandle is! String ||
        (displayName != null && displayName is! String) ||
        isBot is! bool ||
        addedAt is! String ||
        nameChangedAt is! int) {
      return null;
    }
    final added = DateTime.tryParse(addedAt);
    if (added == null) return null;
    final contact = SyncedContact(
      deviceId: deviceId,
      userHandle: userHandle,
      displayName: displayName as String?,
      isBot: isBot,
      addedAt: added,
      nameChangedAt: nameChangedAt,
    );
    return contact.isValid ? contact : null;
  }
}

/// Trims a name; blank becomes null (the same rule as a local rename).
String? normalizeSyncedName(String? name) {
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A conversation header of a snapshot, never with messages.
class SyncedConversation {
  const SyncedConversation({
    required this.id,
    required this.type,
    this.title,
    this.organizationId,
    this.organizationName,
  });

  final String id;

  /// `direct` or `group`.
  final String type;
  final String? title;
  final String? organizationId;
  final String? organizationName;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'organizationId': organizationId,
    'organizationName': organizationName,
  };

  static SyncedConversation? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final type = json['type'];
    final title = json['title'];
    final organizationId = json['organizationId'];
    final organizationName = json['organizationName'];
    String? optional(Object? v, int max) =>
        v is String && v.length <= max ? v : null;
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        (type != 'direct' && type != 'group') ||
        (title != null && optional(title, 200) == null) ||
        (organizationId != null && optional(organizationId, 64) == null) ||
        (organizationName != null && optional(organizationName, 200) == null)) {
      return null;
    }
    return SyncedConversation(
      id: id,
      type: type as String,
      title: title as String?,
      organizationId: organizationId as String?,
      organizationName: organizationName as String?,
    );
  }
}

/// What a `contact-sync` body says.
enum ContactSyncOp { upsert, snapshot, remove }

/// The body of a `contact-sync` message.
class ContactSyncPayload {
  const ContactSyncPayload._(
    this.op, {
    this.contacts = const [],
    this.conversations = const [],
    this.removedDeviceIds = const [],
    this.changedAt = 0,
  });

  /// Some contacts changed (added or renamed).
  factory ContactSyncPayload.upsert(List<SyncedContact> contacts) =>
      ContactSyncPayload._(ContactSyncOp.upsert, contacts: contacts);

  /// One part of a full snapshot; see [snapshots] for splitting.
  factory ContactSyncPayload.snapshot(
    List<SyncedContact> contacts,
    List<SyncedConversation> conversations,
  ) => ContactSyncPayload._(
    ContactSyncOp.snapshot,
    contacts: contacts,
    conversations: conversations,
  );

  /// Contacts deleted at [changedAt] (ms). No delete exists in the app yet.
  factory ContactSyncPayload.remove(List<String> deviceIds, int changedAt) =>
      ContactSyncPayload._(
        ContactSyncOp.remove,
        removedDeviceIds: deviceIds,
        changedAt: changedAt,
      );

  final ContactSyncOp op;
  final List<SyncedContact> contacts;
  final List<SyncedConversation> conversations;
  final List<String> removedDeviceIds;
  final int changedAt;

  /// A full snapshot as as many messages as the limits need (at least one,
  /// so an empty device list still tells the receiver "nothing").
  static List<ContactSyncPayload> snapshots(
    List<SyncedContact> contacts,
    List<SyncedConversation> conversations,
  ) {
    final parts = <ContactSyncPayload>[];
    for (
      var i = 0;
      i == 0 ||
          i * maxContactSyncEntries < contacts.length ||
          i * maxContactSyncEntries < conversations.length;
      i++
    ) {
      List<T> slice<T>(List<T> all) => all
          .skip(i * maxContactSyncEntries)
          .take(maxContactSyncEntries)
          .toList();
      parts.add(
        ContactSyncPayload.snapshot(slice(contacts), slice(conversations)),
      );
    }
    return parts;
  }

  /// The `body` string. Throws [ArgumentError] for what a receiver would
  /// drop, so a bug shows up at the sender.
  String encode() {
    if (contacts.length > maxContactSyncEntries ||
        conversations.length > maxContactSyncEntries ||
        removedDeviceIds.length > maxContactSyncEntries) {
      throw ArgumentError('too many entries, split the snapshot');
    }
    return jsonEncode(switch (op) {
      ContactSyncOp.upsert => {
        'op': 'upsert',
        'contacts': [for (final c in contacts) c.toJson()],
      },
      ContactSyncOp.snapshot => {
        'op': 'snapshot',
        'contacts': [for (final c in contacts) c.toJson()],
        'conversations': [for (final c in conversations) c.toJson()],
      },
      ContactSyncOp.remove => {
        'op': 'remove',
        'deviceIds': removedDeviceIds,
        'changedAt': changedAt,
      },
    });
  }

  /// Parses a received body; null when the message as a whole is invalid
  /// (unknown op, a list over the limit, not JSON). Invalid entries are
  /// left out.
  static ContactSyncPayload? decode(Object? body) {
    if (body is! String || body.length > 4 * 1024 * 1024) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final map = json;
    List<Object?>? list(String key, {bool required = true}) {
      final value = map[key];
      if (value == null && !required) return const [];
      if (value is! List || value.length > maxContactSyncEntries) return null;
      return value;
    }

    switch (json['op']) {
      case 'upsert':
        final raw = list('contacts');
        if (raw == null) return null;
        return ContactSyncPayload.upsert(_contacts(raw));
      case 'snapshot':
        final rawContacts = list('contacts');
        final rawConversations = list('conversations', required: false);
        if (rawContacts == null || rawConversations == null) return null;
        return ContactSyncPayload.snapshot(_contacts(rawContacts), [
          for (final c in rawConversations) ?SyncedConversation.tryParse(c),
        ]);
      case 'remove':
        final raw = list('deviceIds');
        final changedAt = json['changedAt'];
        if (raw == null || changedAt is! int || changedAt < 0) return null;
        return ContactSyncPayload.remove([
          for (final id in raw)
            if (id is String && _guid.hasMatch(id)) id,
        ], changedAt);
      default:
        return null;
    }
  }

  static List<SyncedContact> _contacts(List<Object?> raw) => [
    for (final c in raw) ?SyncedContact.tryParse(c),
  ];
}

/// Whether a name written at [remoteAt] replaces the local one written at
/// [localAt]: last writer wins; on a tie the larger name wins (null is the
/// smallest), so every device ends with the same name whatever the order
/// in which the copies arrive.
bool remoteNameWins({
  required int localAt,
  required String? localName,
  required int remoteAt,
  required String? remoteName,
}) {
  if (remoteAt != localAt) return remoteAt > localAt;
  if (remoteName == localName) return false;
  if (localName == null) return true;
  if (remoteName == null) return false;
  return remoteName.compareTo(localName) > 0;
}
