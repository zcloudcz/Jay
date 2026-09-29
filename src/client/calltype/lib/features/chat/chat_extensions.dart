import 'package:flutter/widgets.dart';

import '../../core/storage/database.dart';

// Extension points of the chat UI for message types the chat core does not
// render itself (contract M §4.5; docs/superpowers/plans/2026-09-29-gap-contracts.md
// §5). Wave 0 creates only the shapes: `main.dart` provides
// `ChatExtensions.none`, stream M (M06) consults them in the chat screen and
// stream M2 (M2-10) swaps in the media implementation. Keeping the seam here
// lets M and M2 work in parallel without editing each other's files.

/// Builds the content of a message bubble for one message type.
typedef MessageBodyBuilder =
    Widget Function(
      BuildContext context,
      Message message, {
      required bool isMine,
    });

/// One entry of the composer's "+" menu (photo, video, file…).
class ComposerAction {
  const ComposerAction({
    required this.icon,
    required this.label,
    required this.onInvoke,
  });

  final IconData icon;

  /// Localized label; a function because the text depends on the context's
  /// locale and code outside a BuildContext must not localize (CLAUDE.md).
  final String Function(BuildContext) label;

  /// [replyTo] is the message being replied to, if any.
  ///
  /// TODO(X0 merge): the contract types it as `ReplyRef?` from
  /// `outgoing_messages.dart` (K4), which is created by another X0 part and
  /// does not exist on this branch yet. The coordinator replaces `Object?`
  /// with `ReplyRef?` (and adds `import 'outgoing_messages.dart';`) when both
  /// branches are merged. Nothing calls this before then.
  final Future<void> Function(
    BuildContext context,
    String conversationId,
    Object? replyTo,
  )
  onInvoke;
}

/// Hooks that teach the chat UI about one `Message.type`.
///
/// Every hook is optional: a type without a [bodyBuilder] falls back to the
/// generic "requires a newer version of Jay" placeholder (contracts K1).
class MessageTypeHooks {
  const MessageTypeHooks({
    this.bodyBuilder,
    this.previewText,
    this.searchableText,
    this.prepareForwardBody,
    this.onDeleted,
  });

  /// Content of the bubble.
  final MessageBodyBuilder? bodyBuilder;

  /// One-line text for the chat list, quotes and notifications.
  final String Function(BuildContext, Message)? previewText;

  /// Text indexed by full-text search (e.g. a photo caption), null = none.
  final String? Function(Message)? searchableText;

  /// Body to send when forwarding (lets media reuse the uploaded blob).
  final Future<String> Function(Message)? prepareForwardBody;

  /// Cleanup of local files when the message is deleted.
  final Future<void> Function(Message)? onDeleted;
}

/// All chat extensions of the running app.
class ChatExtensions {
  const ChatExtensions({
    this.types = const {},
    this.attachmentActions = const [],
    this.trailingWhenEmpty,
  });

  /// Key = `Message.type`, e.g. `'media'`.
  final Map<String, MessageTypeHooks> types;

  /// Items of the composer's "+" menu.
  final List<ComposerAction> attachmentActions;

  /// Replaces the send button while the input is empty (voice note).
  final Widget Function(BuildContext, String conversationId)? trailingWhenEmpty;

  /// No extensions: the app behaves exactly as before wave 0.
  static const none = ChatExtensions();
}
