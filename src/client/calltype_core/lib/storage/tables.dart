import 'package:drift/drift.dart';

/// Known contacts — devices we have exchanged identity keys with.
///
/// Each contact is identified by their device UUID (not an account ID)
/// because CallType is anonymous-first: a device IS an identity until
/// the user optionally registers an account. The [identityKey] is the
/// public part of the Signal Protocol identity key pair, stored as raw
/// bytes so it can be fed directly into libsignal without re-encoding.
class Contacts extends Table {
  /// Remote device UUID — primary identity in anonymous mode.
  TextColumn get deviceId => text()();

  /// Human-readable handle (e.g. CT-A1B2-C3D4) for display.
  TextColumn get userHandle => text()();

  /// Optional friendly name set by the local user.
  TextColumn get displayName => text().nullable()();

  /// Signal Protocol identity public key (raw bytes).
  BlobColumn get identityKey => blob()();

  /// Whether the identity key has been verified out-of-band
  /// (e.g. via QR code safety number comparison).
  BoolColumn get verified => boolean().withDefault(const Constant(false))();

  /// When this contact was first added locally.
  DateTimeColumn get addedAt => dateTime()();

  /// Self-declared by the remote device at registration (server `isBot`).
  /// NOT a verification — it only drives the "BOT" badge, the third-party
  /// notice and hiding of call buttons (bots cannot take calls).
  BoolColumn get isBot => boolean().withDefault(const Constant(false))();

  /// v4 (S, G): when the local user last verified this contact out of band
  /// (safety number / QR). Null = not verified. [verified] stays and is
  /// written together with this column until stream D moves the backup
  /// format over — older backups and older code only know the boolean.
  DateTimeColumn get verifiedAt => dateTime().nullable()();

  /// v4 (S, G): set when the peer's identity key changed and the change has
  /// not been accepted yet (drives the "identity changed" banner). Null = no
  /// pending change.
  DateTimeColumn get identityKeyChangedAt => dateTime().nullable()();

  /// v4 (D, used from wave 2): version of this contact's signed device list
  /// we last applied. Null = single-device contact / never received one.
  IntColumn get deviceListVersion => integer().nullable()();

  /// v4 (D): pinned base64 Ed25519 signing key of the contact's PRIMARY
  /// device — the root that signs their device list. Pinned like the
  /// identity key so a server cannot inject a device into the list.
  TextColumn get deviceListRoot => text().nullable()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// Conversations — both 1:1 (direct) and group chats.
///
/// Conversations act as the top-level grouping for messages. The [type]
/// column distinguishes direct from group so the UI can render them
/// differently (e.g. group avatar vs. single avatar). Using a text enum
/// instead of an int keeps the DB human-readable for debugging.
class Conversations extends Table {
  /// Locally generated UUID.
  TextColumn get id => text()();

  /// 'direct' or 'group' — determines rendering and encryption strategy
  /// (pairwise Double Ratchet vs. Sender Keys).
  TextColumn get type => text()();

  /// Display title — null for direct chats (derived from contact name),
  /// user-defined for groups.
  TextColumn get title => text().nullable()();

  /// Timestamp of the most recent message, used for sorting the chat list.
  DateTimeColumn get lastMessageAt => dateTime().nullable()();

  /// Badge count — reset to 0 when the user opens the conversation.
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  /// Business mode (Jay): set once when a group is created under an
  /// organization, or backfilled after fetching `GET /groups/{id}` the first
  /// time an existing business conversation is opened. Null = anonymous —
  /// cached locally rather than re-fetched per row so the chat list can show
  /// the archive badge without an API call per conversation (KB1/E05).
  TextColumn get organizationId => text().nullable()();

  /// Display name of the organization, cached alongside [organizationId] for
  /// the banner/badge — avoids a second lookup just to show a label.
  TextColumn get organizationName => text().nullable()();

  /// v4 (M): muted until this instant. Null = not muted; "forever" is the
  /// sentinel `mutedForever` (database.dart) rather than a separate flag, so "is muted" is
  /// always the single check `mutedUntil > now`.
  DateTimeColumn get mutedUntil => dateTime().nullable()();

  /// v4 (M): unsent composer text, restored when the chat is reopened.
  TextColumn get draft => text().nullable()();

  /// v4 (M): pinned to the top of the chat list; null = not pinned. A
  /// timestamp instead of a bool so several pins keep a stable order.
  DateTimeColumn get pinnedAt => dateTime().nullable()();

  /// v4 (M): archived (hidden from the main list); null = not archived.
  DateTimeColumn get archivedAt => dateTime().nullable()();

  /// v4 (G): this device is no longer a member of the group (left or was
  /// removed). The history stays readable, only the composer is hidden.
  DateTimeColumn get leftAt => dateTime().nullable()();

  /// v4 (G): SENDER's timestamp of the last applied rename — last-write-wins
  /// for concurrent `group-update rename` messages from different admins.
  DateTimeColumn get titleUpdatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Individual messages within a conversation.
///
/// Messages are stored locally after decryption. The server never sees
/// plaintext — it only relays opaque blobs. The [status] column tracks
/// delivery state so the UI can show single-check / double-check / clock
/// indicators similar to WhatsApp.
///
/// The (conversation_id, created_at) index (v4) backs the chat screen query
/// — one conversation, newest first — which otherwise scans every message.
@TableIndex(
  name: 'idx_messages_conversation_created',
  columns: {#conversationId, #createdAt},
)
class Messages extends Table {
  /// Globally unique message ID (UUID, generated by sender).
  TextColumn get id => text()();

  /// Foreign key to [Conversations.id].
  TextColumn get conversationId => text()();

  /// Device ID of the sender (may be self for outgoing messages).
  TextColumn get senderId => text()();

  /// Decrypted message body. Null for non-text message types
  /// (e.g. image-only, file attachment).
  TextColumn get body => text().nullable()();

  /// Message content type as it came over the wire: 'text', 'file',
  /// 'call-event', 'media' (M2), 'system' (G — a LOCAL-only group/identity
  /// event line, body = JSON, never sent) — or ANY other string: a content
  /// type this app version does not know yet is stored verbatim with its
  /// body (contracts K1) and shown as "needs a newer version of Jay", so an
  /// update can render it later instead of it being lost. Legacy rows may
  /// still say 'image'/'audio'/'video'. Defaults to 'text'.
  TextColumn get type => text().withDefault(const Constant('text'))();

  /// Attachment location, RELATIVE to the app support directory on native
  /// (absolute iOS paths change with the container UUID after an update),
  /// `idb:<key>` on the web (M2 §4.5). Null for text-only.
  TextColumn get attachmentPath => text().nullable()();

  /// Delivery status: 'sending', 'sent', 'delivered', 'read', 'failed'.
  /// Drives the check-mark indicator in the chat UI.
  TextColumn get status => text().withDefault(const Constant('sent'))();

  /// When the message was created by the sender.
  DateTimeColumn get createdAt => dateTime()();

  /// When we received it locally — null for outgoing messages.
  DateTimeColumn get receivedAt => dateTime().nullable()();

  // -- v4 (M §4.3) -----------------------------------------------------------

  /// Id of the quoted message (`replyTo.id`).
  TextColumn get replyToId => text().nullable()();

  /// Author of the quoted message — kept so the quote can show a name even
  /// when the original is not (or no longer) stored locally.
  TextColumn get replyToSenderId => text().nullable()();

  /// Snapshot of the quoted text, at most 100 characters.
  TextColumn get replyPreview => text().nullable()();

  /// "Forwarded" label.
  BoolColumn get forwarded => boolean().withDefault(const Constant(false))();

  /// Last applied edit (sender's clock); history in [MessageRevisions].
  DateTimeColumn get editedAt => dateTime().nullable()();

  /// Tombstone of "delete for everyone"; the row stays so replays and
  /// late reactions still find their target.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// Incoming only: when THIS user read it.
  DateTimeColumn get readAt => dateTime().nullable()();

  /// Incoming only: highest receipt already sent back, 'delivered' | 'read'.
  /// The v3→v4 migration sets 'read' on every existing row, otherwise the
  /// first v4 start would send receipts for the whole history.
  TextColumn get receiptSent => text().nullable()();

  /// RESERVED for disappearing messages (M11) — do not use yet.
  DateTimeColumn get expiresAt => dateTime().nullable()();

  // -- v4 (M2 §4.5) ----------------------------------------------------------

  /// `MediaRef.blobId` of a `media` message: finds the bubble for a blob
  /// (cache eviction, transfer progress) without parsing every body.
  TextColumn get mediaBlobId => text().nullable()();

  /// UI state of the media transfer: preparing|uploading|uploaded|queued|
  /// downloading|ready|failed|expired — kept here so a build does not have
  /// to parse the JSON body for every bubble.
  TextColumn get mediaState => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One reaction per person and message (M §4.3). Last-write-wins on the
/// SENDER's `createdAt` ([updatedAt]) so replays and reordering converge.
/// The target message may not exist (yet): such rows are ignored by the UI
/// and removed by housekeeping.
class Reactions extends Table {
  TextColumn get messageId => text()();

  /// Device id of whoever reacted (mine included).
  TextColumn get reactorId => text()();
  TextColumn get emoji => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {messageId, reactorId};
}

/// Delivery/read state of an OUTGOING message per recipient. The auditor is
/// never a row — it is a silent archive, not a reader.
class MessageReceipts extends Table {
  TextColumn get messageId => text()();
  TextColumn get recipientId => text()();
  DateTimeColumn get deliveredAt => dateTime().nullable()();
  DateTimeColumn get readAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {messageId, recipientId};
}

/// Edit history; revision 0 is the original text.
class MessageRevisions extends Table {
  TextColumn get messageId => text()();
  IntColumn get revision => integer()();
  TextColumn get body => text()();
  DateTimeColumn get editedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {messageId, revision};
}

/// EVERY processed incoming message id — content, control and unknown.
///
/// WHY: deduplication used to rely on a row in [Messages] only, but control
/// messages (receipt, reaction, …) never get one. When an ACK is lost the
/// server redelivers; the ratchet key is already consumed, decryption
/// fails, and the message would be retried as an error for 30 days. The
/// inbox checks this table BEFORE decrypting. Rows older than 35 days
/// (queue TTL 30 days + margin) are pruned by M02 at startup.
@DataClassName('InboundLogEntry')
class InboundLog extends Table {
  TextColumn get senderId => text()();
  TextColumn get messageId => text()();
  DateTimeColumn get processedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {senderId, messageId};
}

/// Small settings shared by several streams (contracts K12). Keys are
/// `<scope>.<key>` (`privacy.*`, `notif.*`, `profile.*`, `media.*`, `sec.*`,
/// `calls.*`); anything device-specific starts with `local.` and is NEVER
/// included in a backup. Not for secrets — this database is plaintext.
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Resumable upload/download of one encrypted media blob (M2 §4.5). The
/// primary key is the message id because one message carries one blob.
class AttachmentTransfers extends Table {
  TextColumn get messageId => text()();

  /// 'up' | 'down'.
  TextColumn get direction => text()();

  /// Upload: only known after `POST /attachments`.
  TextColumn get blobId => text().nullable()();

  /// Relative path / `idb:<key>` of the plaintext (the sender's copy or the
  /// download target).
  TextColumn get localPath => text().nullable()();

  /// Upload: the key is generated BEFORE the upload so a restart resumes
  /// with the same key. Plaintext DB on purpose — the message bodies, which
  /// carry the same key inside MediaRef, live here too.
  TextColumn get keyB64 => text().nullable()();

  /// Upload: MediaRef JSON without blobId (mime, dimensions, thumbnail …).
  TextColumn get refDraft => text().nullable()();
  IntColumn get totalBytes => integer()();
  IntColumn get doneBytes => integer().withDefault(const Constant(0))();
  IntColumn get chunkSize => integer().nullable()();

  /// 'queued' | 'running' | 'paused' | 'failed' | 'done'.
  TextColumn get state => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// `AttachmentErrorCode.name`, never an exception text (nothing to leak).
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {messageId};
}

/// Profiles as DECLARED by peers (and mine under my own device id), G §4.1.
///
/// WHY a separate table instead of columns on [Contacts] (contracts K8):
/// profiles also arrive from group members who are not contacts, and the
/// data must survive deleting a contact.
class PeerProfiles extends Table {
  TextColumn get deviceId => text()();

  /// ≤ 40 chars, without control / bidi-override characters.
  TextColumn get displayName => text().nullable()();

  /// ≤ 140 chars.
  TextColumn get about => text().nullable()();

  /// JPEG 48×48, ≤ 2 KiB — arrives inline in the `profile` message.
  BlobColumn get avatarThumb => blob().nullable()();

  /// JPEG 256×256, ≤ 64 KiB — the downloaded blob. A blob column (not a
  /// file path) so it works on the web too, which has no file system.
  BlobColumn get avatarImage => blob().nullable()();

  /// MediaRef JSON; on my own row the last uploaded avatar.
  TextColumn get avatarRef => text().nullable()();

  /// Only on my own row: re-upload after TTL/2.
  DateTimeColumn get avatarUploadedAt => dateTime().nullable()();
  IntColumn get version => integer().withDefault(const Constant(0))();

  /// Declared by the sender.
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get receivedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// Blocked devices, independent of [Contacts] (G §4.1, contracts K8): a
/// stranger can be blocked too, and deleting a contact must not unblock.
/// Same pattern as [BlockedChannels]. Read through `PeerDirectory` in the
/// app, or `isDeviceBlocked` (block_list.dart) where there is no widget
/// tree (notification isolate, inbox).
class BlockedDevices extends Table {
  TextColumn get deviceId => text()();
  TextColumn get userHandle => text().nullable()();
  DateTimeColumn get blockedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// Devices of a person (D §4.1, used from wave 2; part of v4 so wave 2 does
/// not need a v5 just for this table). Historical rows are never deleted,
/// only marked [removedAt], so old messages keep their author.
@TableIndex(name: 'contact_devices_contact', columns: {#contactId})
class ContactDevices extends Table {
  TextColumn get deviceId => text()();

  /// `Contacts.deviceId` (anchor of the direct conversation), or the
  /// reserved `'self'` for my own devices. For group members who are not
  /// contacts: the primaryDeviceId of their list.
  TextColumn get contactId => text()();
  BlobColumn get identityKey => blob().nullable()();

  /// base64 Ed25519 public key.
  TextColumn get signingKey => text().nullable()();

  /// From the device list, max 64 chars.
  TextColumn get name => text().nullable()();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get removedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// Local-only call history (anonymous AND business calls), C §5.5. Never
/// synced, never sent — the server keeps no call history by design.
@DataClassName('CallLogEntry')
@TableIndex.sql(
  'CREATE INDEX call_log_started_at ON call_log (started_at DESC)',
)
@TableIndex(
  name: 'call_log_conversation',
  columns: {#conversationId, #startedAt},
)
class CallLog extends Table {
  /// UUID v4 — also the CallKit UUID.
  TextColumn get callId => text()();

  /// Null only for a pushed call cancelled before we learned the caller.
  TextColumn get peerId => text().nullable()();

  /// businessGroupId, else peerId.
  TextColumn get conversationId => text().nullable()();

  /// 'outgoing' | 'incoming'.
  TextColumn get direction => text()();
  BoolColumn get video => boolean().withDefault(const Constant(false))();

  /// Local outcome set (C KC6): completed | missed | declined | busy |
  /// unavailable | noAnswer | cancelled | failed — NOT the H1 whitelist.
  TextColumn get outcome => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get connectedAt => dateTime().nullable()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// Missed-call badge; null = not seen yet.
  DateTimeColumn get seenAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {callId};
}

/// Persisted Signal Protocol session state.
///
/// Each entry stores the serialized Double Ratchet session for one
/// remote address (device). Stored as an opaque blob because the
/// session structure is owned by libsignal — we just persist and
/// restore it without interpreting the contents.
class SignalSessions extends Table {
  /// Signal Protocol address string (typically "deviceId.deviceIndex").
  TextColumn get address => text()();

  /// Serialized session state from libsignal.
  BlobColumn get sessionData => blob()();

  @override
  Set<Column> get primaryKey => {address};
}

/// Generic key-value store for small pieces of state that don't
/// warrant their own table — e.g. last backup timestamp, schema
/// migration flags, feature toggles.
///
/// NOT for secrets (use [SecureStorage] for those) — this table
/// lives in the unencrypted SQLite database.
class BackupState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Followed / administered public channels (WhatsApp-Channels style).
///
/// WHY separate tables instead of reusing [Conversations]/[Messages]: a
/// channel is NOT a conversation — its posts are public plaintext that the
/// server can read, so they must never mix with the E2E-encrypted chat
/// history, the chat list or chat backups.
class Channels extends Table {
  TextColumn get channelId => text()();

  /// Public discovery handle (CH-XXXX-XXXX) used in links and QR codes.
  TextColumn get handle => text()();
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();

  /// Aggregate only — the server never reveals who the followers are.
  IntColumn get followerCount => integer().withDefault(const Constant(0))();

  /// 'owner' / 'admin' when this device may publish, null for a follower.
  TextColumn get role => text().nullable()();

  /// An owner/admin may stop following yet still has to see the channel in
  /// order to manage it, so "listed" and "following" are separate facts.
  BoolColumn get isFollowing => boolean().withDefault(const Constant(true))();

  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// Local cache of channel posts (public plaintext, see [Channels]).
class ChannelPosts extends Table {
  /// Generated by the publishing client; the primary key makes a replayed
  /// hub event or an overlapping sync page a no-op instead of a duplicate.
  TextColumn get postId => text()();
  TextColumn get channelId => text()();

  /// 'text' | 'image' | 'poll'.
  TextColumn get kind => text()();

  /// Text, image caption, or the poll JSON {question, options[], closesAt?}.
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get attachmentBlobPath => text().nullable()();

  /// UTC ISO-8601 string, NOT a drift DateTime: drift stores DateTime with
  /// second precision, but this exact value is sent back to the server as
  /// the `after` / `before` paging cursor. Fixed-width UTC ISO strings also
  /// sort correctly as text.
  TextColumn get createdAt => text()();

  /// JSON object emoji -> count. Only totals exist; who reacted is never
  /// exposed by the API.
  TextColumn get reactions => text().withDefault(const Constant('{}'))();
  TextColumn get myReaction => text().nullable()();

  /// JSON array with the vote count per poll option.
  TextColumn get pollVotes => text().withDefault(const Constant('[]'))();
  IntColumn get myVote => integer().nullable()();

  @override
  Set<Column> get primaryKey => {postId};
}

/// Channels the user blocked. Purely client-side (plan §7.5): the server is
/// only told "unfollow". The handle is stored because links and QR codes
/// carry the handle, not the id, and a blocked channel must not be
/// reopenable from a link without unblocking first.
class BlockedChannels extends Table {
  TextColumn get channelId => text()();
  TextColumn get handle => text()();
  TextColumn get name => text()();
  DateTimeColumn get blockedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {channelId};
}
