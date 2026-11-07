import 'package:calltype_core/network/group_dtos.dart' show MuteMode;
import 'package:flutter/widgets.dart' show StringCharacters;

import '../../l10n/l10n.dart';

/// What a notification is about. The wire names and Android channel ids are
/// fixed by the notifications contract (spec 2026-11-06, section 1.3): a
/// server push and a local notification for the same event must land in the
/// same Android channel and open the same screen.
enum NotificationKind {
  message('message', 'messages'),
  groupMessage('group_message', 'messages'),
  incomingCall('incoming_call', 'calls'),
  channelPost('channel_post', 'channels');

  const NotificationKind(this.wireType, this.androidChannelId);

  /// `type` in the push data.
  final String wireType;

  /// Android notification channel (`android.notification.channel_id`).
  final String androidChannelId;

  static NotificationKind? parse(Object? raw) {
    for (final kind in values) {
      if (kind.wireType == raw) return kind;
    }
    return null;
  }
}

/// Where tapping a notification leads: the conversation (or channel feed)
/// named by `conversationId` in the push data, for server pushes and local
/// notifications alike (spec N6).
class NotificationTarget {
  const NotificationTarget(this.kind, this.conversationId);

  final NotificationKind kind;
  final String conversationId;

  /// WHY strict: the id comes from a push payload (or a web URL / service
  /// worker message) and is pasted into a route. Anything that is not a plain
  /// id (a group / device / channel GUID) must not be able to steer the router
  /// somewhere else, e.g. `../settings`.
  static final _id = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  /// Parses push data `{type, conversationId, v}`; null when unusable.
  static NotificationTarget? fromData(Map<String, Object?> data) {
    final kind = NotificationKind.parse(data['type']);
    final id = data['conversationId'];
    if (kind == null || id is! String || !_id.hasMatch(id)) return null;
    return NotificationTarget(kind, id);
  }

  /// The data a local notification carries, same keys as a server push so
  /// one tap handler serves both.
  Map<String, String> toData() => {
    'type': kind.wireType,
    'conversationId': conversationId,
    'v': '1',
  };

  /// The app route to open. A call opens its chat: the call itself is long
  /// gone (or rings in the call screen the overlay already shows).
  String get route => switch (kind) {
    NotificationKind.channelPost => '/channels/feed/$conversationId',
    _ => '/chats/$conversationId',
  };

  /// Route for a tap: the target's, or the chat list when the data is not
  /// usable (old server, malformed payload).
  static String routeFor(Map<String, Object?> data) =>
      fromData(data)?.route ?? '/chats';

  @override
  bool operator ==(Object other) =>
      other is NotificationTarget &&
      other.kind == kind &&
      other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(kind, conversationId);
}

/// Why an event does NOT produce a local notification. Null = show it.
enum NotificationSkip {
  /// The user turned notifications off.
  disabled,

  /// Written on another device of this identity: the user knows already.
  ownDevice,

  /// The user is looking at exactly this conversation right now.
  conversationOpen,

  /// The per-device conversation mute (spec D6) covers it.
  muted,
}

/// The decision of spec section 2, kept pure so every rule is unit tested.
///
/// [openConversationId] is the conversation (or channel) on screen, null
/// when none; [appFocused] means the app is in the foreground AND has focus
/// (a visible but unfocused desktop window still gets notifications).
NotificationSkip? notificationSkip({
  required bool enabled,
  required NotificationKind kind,
  required String conversationId,
  required bool fromSelf,
  required bool appFocused,
  required String? openConversationId,
  required MuteMode mute,
  bool senderIsBot = false,
}) {
  if (!enabled) return NotificationSkip.disabled;
  if (fromSelf) return NotificationSkip.ownDevice;
  if (appFocused) {
    // A ringing call already takes over the focused app (SessionOverlay
    // pushes the call screen), a notification on top would be noise.
    if (kind == NotificationKind.incomingCall) {
      return NotificationSkip.conversationOpen;
    }
    if (openConversationId != null &&
        openConversationId.toLowerCase() == conversationId.toLowerCase()) {
      return NotificationSkip.conversationOpen;
    }
  }
  switch (kind) {
    case NotificationKind.message:
    case NotificationKind.groupMessage:
      if (mute == MuteMode.all) return NotificationSkip.muted;
      if (mute == MuteMode.bots && senderIsBot) return NotificationSkip.muted;
    case NotificationKind.incomingCall:
      // Same rule as the server's call push (contract 1.3): only "all"
      // silences a call; "bots only" is about bot chatter, not people calling.
      if (mute == MuteMode.all) return NotificationSkip.muted;
    case NotificationKind.channelPost:
      // Channels have no mute: unfollow / block is the control there.
      break;
  }
  return null;
}

/// What a message is, for the notification body. Only [text] carries
/// content; the others become a localized label (a media file shows its
/// name, encrypted media contract section 3).
enum PreviewKind { text, photo, file, poll, voice, video, audio }

class MessagePreview {
  const MessagePreview.text(this.text) : kind = PreviewKind.text;
  const MessagePreview.label(this.kind) : text = null;
  const MessagePreview.fileName(String this.text) : kind = PreviewKind.file;

  final PreviewKind kind;
  final String? text;
}

/// Longest body text taken from a message (spec section 2).
const maxPreviewLength = 120;

/// Single-line, at most [maxPreviewLength] user-perceived characters (never
/// cuts an emoji or a combining sequence in half), with an ellipsis when cut.
String truncatePreview(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final chars = flat.characters;
  if (chars.length <= maxPreviewLength) return flat;
  return '${chars.take(maxPreviewLength - 1)}\u2026';
}

class NotificationText {
  const NotificationText(this.title, this.body);
  final String title;
  final String body;
}

/// Title and body of a local notification.
///
/// [title] is the contact, group or channel name ("Jay" when unknown).
/// With [previews] off the body is the same generic text a server push
/// shows, so a hidden preview never leaks content on the lock screen; the
/// title stays, as the contract says (spec section 2).
NotificationText notificationText({
  required AppLocalizations l10n,
  required NotificationKind kind,
  required String? title,
  required bool previews,
  MessagePreview? preview,
  String? senderName,
}) {
  final heading = (title == null || title.trim().isEmpty) ? 'Jay' : title;
  final generic = genericNotificationBody(l10n, kind);
  if (!previews || preview == null || kind == NotificationKind.incomingCall) {
    return NotificationText(heading, generic);
  }
  final content = switch (preview.kind) {
    PreviewKind.text => truncatePreview(preview.text ?? ''),
    PreviewKind.photo => l10n.notificationPhoto,
    PreviewKind.file =>
      preview.text == null
          ? l10n.notificationFile
          : truncatePreview(preview.text!),
    PreviewKind.poll => l10n.notificationPoll,
    PreviewKind.voice => l10n.notificationVoice,
    PreviewKind.video => l10n.notificationVideo,
    PreviewKind.audio => l10n.notificationAudio,
  };
  if (content.isEmpty) return NotificationText(heading, generic);
  final body =
      kind == NotificationKind.groupMessage &&
          senderName != null &&
          senderName.isNotEmpty
      ? l10n.notificationGroupBody(senderName, content)
      : content;
  return NotificationText(heading, body);
}

/// The generic text of each kind, identical in meaning to the server's
/// push body (contract 1.3).
String genericNotificationBody(AppLocalizations l10n, NotificationKind kind) =>
    switch (kind) {
      NotificationKind.message => l10n.notificationNewMessage,
      NotificationKind.groupMessage => l10n.notificationNewGroupMessage,
      NotificationKind.incomingCall => l10n.notificationIncomingCall,
      NotificationKind.channelPost => l10n.notificationNewChannelPost,
    };

/// A stable 31-bit notification id per kind + conversation, so a newer
/// notification of the same chat REPLACES the older one (spec N4 collapse)
/// on every platform. FNV-1a, because `String.hashCode` is not stable across
/// runs and a restarted app must still replace what it showed before.
int notificationIdFor(NotificationKind kind, String conversationId) {
  final key = '${kind.androidChannelId}:${conversationId.toLowerCase()}';
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'};

/// Photo or plain file, from an attachment's file name.
PreviewKind attachmentPreviewKind(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  return _imageExtensions.contains(ext) ? PreviewKind.photo : PreviewKind.file;
}
