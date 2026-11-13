import 'dart:convert';

import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/network/webrtc_manager.dart';
import '../../core/network/signalr_client.dart';
import '../contacts/contacts_controller.dart';
import '../chat_list/chat_list_controller.dart';
import 'chat_controller.dart';
import 'chat_delete_dialogs.dart';
import 'chat_deletion.dart';
import 'chat_message_list.dart';
import 'message_bubble.dart';
import 'pin_widgets.dart';
import 'pins.dart' show maxPinsPerConversation;
import 'poll_widgets.dart';
import 'polls.dart';
import 'reaction_widgets.dart';
import 'message_input.dart';
import 'mentions.dart';
import 'participant_colors.dart';
import '../contacts/rename_contact_dialog.dart';
import '../groups/group_topic_widgets.dart' show GroupHeaderTitle;
import 'package:flutter/services.dart';
import 'attachment.dart';
import 'attachment_media.dart';
import 'attachment_sheet.dart';
import 'image_attachment.dart';
import 'image_compression.dart';
import 'photo_send_preview.dart';
import 'bot_commands.dart';
import 'package:calltype_core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/bot_badge.dart';
import '../media/media_bubble.dart';
import '../media/media_device.dart';
import '../media/media_message.dart';
import '../media/media_store.dart';
import '../media/media_thumbnail.dart';
import '../media/voice_composer.dart';
import '../mute/mute_dialog.dart';
import '../organization/business_banner.dart';

/// One-time notice shown the first time a chat with a bot is opened: the
/// conversation is end-to-end encrypted, but the other end is an automated
/// program run by a third party who can read everything sent to it.
///
/// "Seen" is remembered per contact in the local key-value table so the
/// notice returns for every NEW bot but never nags twice about the same one.
class _BotNotice extends StatefulWidget {
  const _BotNotice({required this.contactId});
  final String contactId;

  @override
  State<_BotNotice> createState() => _BotNoticeState();
}

class _BotNoticeState extends State<_BotNotice> {
  bool _visible = false;
  String get _key => 'bot_notice_seen:${widget.contactId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.read<AppDatabase>();
    final seen = await (db.select(
      db.backupState,
    )..where((s) => s.key.equals(_key))).getSingleOrNull();
    if (mounted && seen == null) setState(() => _visible = true);
  }

  Future<void> _dismiss() async {
    setState(() => _visible = false);
    final db = context.read<AppDatabase>();
    await db
        .into(db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(key: _key, value: '1'),
        );
  }

  @override
  Widget build(BuildContext context) => !_visible
      ? const SizedBox.shrink()
      : MaterialBanner(
          leading: const Icon(Icons.smart_toy_outlined),
          content: Text(context.l10n.botNotice),
          actions: [
            TextButton(onPressed: _dismiss, child: Text(context.l10n.chatBotNoticeDismiss)),
          ],
        );
}

/// Compact "Audio call · 3 min · completed" style line for a `call-event`
/// group message (H2/H1). Never shown as an ordinary bubble — a malformed or
/// unparseable body (should not happen, the archiver validates as strictly)
/// still renders SOMETHING rather than crash the whole message list.
class _CallEventLine extends StatelessWidget {
  const _CallEventLine({required this.body});
  final String body;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      data = null;
    }
    final media = data?['media'] == 'video'
        ? l10n.callEventMediaVideo
        : l10n.callEventMediaAudio;
    final outcome = switch (data?['outcome']) {
      'completed' => l10n.callOutcomeCompleted,
      'missed' => l10n.callOutcomeMissed,
      'rejected' => l10n.callOutcomeRejected,
      'failed' => l10n.callOutcomeFailed,
      'unavailable' => l10n.callOutcomeUnavailable,
      _ => l10n.callOutcomeFailed,
    };
    final startedAt = DateTime.tryParse('${data?['startedAt']}');
    final endedAt = DateTime.tryParse('${data?['endedAt']}');
    final minutes = startedAt != null && endedAt != null
        ? endedAt.difference(startedAt).inMinutes
        : null;
    final line = minutes != null && data?['outcome'] == 'completed'
        ? l10n.callEventLine(media, l10n.callEventMinutes(minutes), outcome)
        : '$media · $outcome';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          line,
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// "This contact added a device" (spec Part A, "What a peer sees"). Written
/// locally by DeviceService when a contact's verified list changes; never
/// sent over the wire.
class _DeviceChangeLine extends StatelessWidget {
  const _DeviceChangeLine({required this.body});
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Center(
      child: Text(
        body == 'removed'
            ? context.l10n.chatDeviceRemoved
            : context.l10n.chatDeviceAdded,
        style: Theme.of(context).textTheme.labelSmall,
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.contactId});
  final String contactId;

  bool _business(BuildContext context) => context
      .read<ChatListController>()
      .conversations
      .any((c) => c.id == contactId && c.organizationId != null);

  /// App bar menu "Delete chat" (spec 2026-11-09-delete-chats-contacts D1):
  /// after the deletion this chat is gone, so go back to the list.
  Future<void> _deleteChat(BuildContext context, {required bool group}) async {
    final deleted = await confirmDeleteChat(
      context,
      conversationId: contactId,
      group: group,
      business: _business(context),
    );
    if (deleted && context.mounted) context.go('/chats');
  }

  Future<void> _leaveGroup(BuildContext context) async {
    final left = await confirmLeaveGroup(
      context,
      groupId: contactId,
      business: _business(context),
    );
    if (left && context.mounted) context.go('/chats');
  }

  /// "Delete contact" (D4); with "Also delete the chat" this chat is gone.
  Future<void> _deleteContact(
    BuildContext context,
    Contact contact,
    String name,
  ) async {
    final result = await confirmDeleteContact(
      context,
      deviceId: contact.deviceId,
      name: name,
    );
    if (result == ContactDeletion.withChat && context.mounted) {
      context.go('/chats');
    }
  }
  Future<void> _call(
    BuildContext context,
    bool video, {
    String? targetDeviceId,
    String? businessGroupId,
  }) async {
    final manager = context.read<WebRTCManager>();
    try {
      await manager.startCall(
        targetDeviceId ?? contactId,
        video: video,
        businessGroupId: businessGroupId,
      );
    } catch (_) {
      if (!context.mounted) return;
      final l10n = context.l10n;
      // A business offer the hub rejected outright never reaches the ringing
      // UI, so it needs its own message here rather than on the call screen.
      final message = switch (manager.error) {
        CallError.auditorUnavailable => l10n.hubErrorAuditorUnavailable,
        CallError.notABusinessMember => l10n.chatCallFailed,
        _ => l10n.chatCallFailed,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  /// [business]: no encrypted media there (see ChatController.sendMedia),
  /// only photos and small inline files.
  Future<void> _attach(BuildContext context, {required bool business}) async {
    final source = await showAttachSourceSheet(
      context,
      media: !business,
      // No polls in business conversations (v1, spec 2026-11-08).
      poll: !business,
    );
    if (source == null || !context.mounted) return;
    final media = AttachmentMedia.instance;
    if (source == AttachSource.file) {
      return _attachFile(context, business: business);
    }
    if (source == AttachSource.poll) return _createPoll(context);
    final device = MediaDevice.instance;
    switch (source) {
      case AttachSource.video:
        return _attachMedia(
          context,
          () => device.pickVideo(camera: false),
          kind: MediaKind.video,
        );
      case AttachSource.videoCamera:
        return _attachMedia(
          context,
          () => device.pickVideo(camera: true),
          kind: MediaKind.video,
        );
      case AttachSource.audio:
        return _attachMedia(
          context,
          () => device.pickFile(audioOnly: true),
          kind: MediaKind.audio,
        );
      default:
    }
    final List<PickedMedia> photos;
    try {
      photos = switch (source) {
        AttachSource.photoLibrary => await media.pickGalleryImages(),
        AttachSource.camera => [?await media.pickCameraImage()],
        _ => await media.pickImageFiles(),
      };
    } catch (_) {
      // Picker refused (permission denied, no camera): nothing was chosen.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.chatAttachmentFailed)),
        );
      }
      return;
    }
    if (photos.isEmpty || !context.mounted) return;
    await _sendPhotos(context, photos);
  }

  /// Photos are re-encoded to fit the inline attachment limit instead of
  /// being rejected: a phone photo (2-6 MB) is ten times the limit, and the
  /// wire format (`type: file`, name + base64 data) stays what old clients
  /// already read. The converted photos are shown for review first: the
  /// user can drop some, add a caption (carried by the first photo) or
  /// cancel the whole send.
  Future<void> _sendPhotos(
    BuildContext context,
    List<PickedMedia> photos,
  ) async {
    final controller = context.read<ChatController>();
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final prepared = await preparePhotos(
      context,
      photos,
      maxBytes: Attachment.maxBytes,
    );
    var tooLarge = false;
    var failed = false;
    final ready = <PreparedPhoto>[];
    for (final photo in prepared) {
      if (photo.bytes != null) {
        ready.add(photo);
      } else if (photo.decoded) {
        tooLarge = true;
      } else {
        failed = true;
      }
    }
    PhotoSendResult? review;
    if (ready.isNotEmpty && context.mounted) {
      review = await showPhotoSendPreview(context, ready);
    }
    for (final (index, photo) in (review?.photos ?? const []).indexed) {
      try {
        await controller.sendAttachment(
          photo.name,
          photo.bytes!,
          caption: index == 0 ? review!.caption : null,
        );
      } catch (_) {
        failed = true;
      }
    }
    // One message per kind of problem, not one per photo.
    if (tooLarge) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.chatAttachmentTooLarge(Attachment.maxBytes ~/ 1024),
          ),
        ),
      );
    }
    if (failed) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.chatAttachmentFailed)),
      );
    }
  }

  /// Small plain files keep the inline path old clients read; audio, video
  /// and anything over the inline limit go through the encrypted media path
  /// (contract M12), streamed, up to the platform cap.
  Future<void> _attachFile(BuildContext context, {required bool business}) =>
      _sendReportingErrors(context, (controller) async {
        final file = await AttachmentMedia.instance.pickFile();
        if (file == null) return;
        final kind = mediaKindFor(file.name, mime: file.mimeType);
        final small = await file.length() <= Attachment.maxBytes;
        if (small &&
            (business || (kind != MediaKind.audio && kind != MediaKind.video))) {
          await controller.sendAttachment(file.name, await file.readAsBytes());
          return;
        }
        await _sendMediaFile(controller, file, kind: kind);
      });

  Future<void> _attachMedia(
    BuildContext context,
    Future<PickedMedia?> Function() pick, {
    required MediaKind kind,
  }) => _sendReportingErrors(context, (controller) async {
    final file = await pick();
    if (file == null) return;
    await _sendMediaFile(controller, file, kind: kind);
  });

  /// Runs an attachment send and turns its failure into one localized
  /// snackbar. Captured before the awaits; the raw exception text is for
  /// developers and is not shown.
  Future<void> _sendReportingErrors(
    BuildContext context,
    Future<void> Function(ChatController controller) send,
  ) async {
    final controller = context.read<ChatController>();
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    void show(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));
    try {
      await send(controller);
    } on MediaNotAllowed {
      // Business conversation: only the inline path exists there.
      show(l10n.chatAttachmentTooLarge(Attachment.maxBytes ~/ 1024));
    } on MediaTooLarge catch (e) {
      show(l10n.mediaTooLarge(formatMediaSize(e.maxBytes)));
    } catch (_) {
      show(l10n.chatAttachmentFailed);
    }
  }

  /// Largest image read into memory for a media-path thumbnail.
  static const _thumbnailSourceLimit = 40 * 1024 * 1024;

  /// Collects what the receiver sees before downloading (thumbnail,
  /// duration, size) and hands the file to [ChatController.sendMedia]. The
  /// video is sent as the original: no maintained compression plugin fits
  /// (spec Limits).
  Future<void> _sendMediaFile(
    ChatController controller,
    PickedMedia file, {
    required MediaKind kind,
  }) async {
    final length = await file.length();
    if (length > controller.media.maxBytes) {
      throw MediaTooLarge(controller.media.maxBytes);
    }
    VideoProbe probe = const VideoProbe();
    if (kind == MediaKind.video && file.path != null) {
      try {
        probe = await MediaDevice.instance.probeVideo(file.path!);
      } catch (_) {}
    } else if (kind == MediaKind.image && length <= _thumbnailSourceLimit) {
      try {
        final thumb = await prepareMediaThumbnail(await file.readAsBytes());
        probe = VideoProbe(
          thumbnail: thumb.thumbnail,
          width: thumb.width,
          height: thumb.height,
        );
      } catch (_) {}
    }
    await controller.sendMedia(
      file,
      kind: kind,
      durationMs: probe.durationMs,
      width: probe.width,
      height: probe.height,
      thumbnail: probe.thumbnail,
    );
  }

  Future<void> _sendVoice(ChatController controller, VoiceClip clip) async {
    try {
      await controller.sendMedia(
        clip.recording.file,
        kind: MediaKind.voice,
        mime: clip.recording.mime,
        durationMs: clip.durationMs,
        waveform: Uint8List.fromList(clip.waveform),
      );
    } finally {
      await clip.recording.cleanup?.call();
    }
  }

  /// "You" for my own messages, else the same name used above group bubbles
  /// (in a direct chat this resolves to the contact).
  String _authorLabel(
    BuildContext context,
    ChatController controller,
    String senderId,
    List<Contact> contacts,
  ) => senderId == controller.myIdentityId
      ? context.l10n.chatYou
      : senderLabel(
          senderId,
          members: controller.groupMembers,
          contacts: contacts,
        );

  /// The person key of [senderId] in this chat (spec
  /// 2026-11-09-participant-colors D3).
  String _personKey(
    ChatController controller,
    String senderId,
    List<Contact> contacts,
  ) => participantKey(
    senderId,
    members: controller.groupMembers,
    contacts: contacts,
  );

  /// The color picker for the sender of a group message (D7 a and b).
  void _pickParticipantColor(
    BuildContext context,
    ParticipantColors store,
    ChatController controller,
    String senderId,
    List<Contact> contacts,
  ) => showParticipantColorSheet(
    context,
    store: store,
    personKey: _personKey(controller, senderId, contacts),
    name: senderLabel(
      senderId,
      members: controller.groupMembers,
      contacts: contacts,
    ),
  );

  /// Copies a message and confirms it; the menu itself lives in
  /// [MessageBubble].
  Future<void> _copy(BuildContext context, String body) async {
    // Captured before the await: the list item's context may be gone by then.
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    // A browser can refuse clipboard access (permission, embedded frame);
    // say so instead of leaving the user guessing whether it worked.
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: body));
    } catch (_) {
      copied = false;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          copied ? l10n.chatMessageCopied : l10n.chatMessageCopyFailed,
        ),
      ),
    );
  }

  /// Delete dialog: "for me" always, "for everyone" only for own, sent
  /// messages outside business conversations.
  Future<void> _delete(
    BuildContext context,
    ChatController controller,
    Message message, {
    required bool canDeleteForEveryone,
  }) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.chatDeleteTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.chatDeleteForMe),
          ),
          if (canDeleteForEveryone)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.chatDeleteForEveryone),
            ),
        ],
      ),
    );
    if (choice == null) return;
    if (!choice) {
      await controller.deleteForMe(message.id);
      return;
    }
    if (!await controller.deleteForEveryone(message.id)) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.chatDeleteForEveryoneFailed)),
      );
    }
  }

  /// Edit dialog for an own text message; sends `type: edit` on save.
  Future<void> _edit(
    BuildContext context,
    ChatController controller,
    Message message,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    // A plain variable, not a TextEditingController: same reason as the
    // add-contact dialog (the controller would be disposed while the exit
    // animation still rebuilds the field).
    var typed = message.body ?? '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.chatEditTitle),
        content: TextFormField(
          initialValue: typed,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          onChanged: (value) => typed = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(typed.trim()),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    // Cancel, an empty text or no change: nothing to send.
    if (text == null || text.isEmpty || text == message.body) return;
    if (!await controller.editMessage(message.id, text)) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.chatEditFailed)));
    }
  }

  /// A pick from the quick bar / picker or a tap on an own chip: the
  /// controller toggles (same emoji again = remove).
  Future<void> _react(
    BuildContext context,
    ChatController controller,
    Message message,
    String emoji,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (!await controller.react(message.id, emoji)) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.chatReactionFailed)));
    }
  }

  /// Who reacted to [message]; the own row removes the own reaction.
  void _showReactors(
    BuildContext context,
    ChatController controller,
    Message message, {
    required List<Contact> contacts,
    required bool canReact,
  }) {
    final mine = controller.myReactionOf(message.id);
    showReactorsSheet(
      context,
      reactions: controller.reactionsOf(message.id),
      nameOf: (id) => _authorLabel(context, controller, id, contacts),
      myId: controller.myIdentityId,
      onRemoveMine: mine == null || !canReact
          ? null
          : () => _react(context, controller, message, mine),
    );
  }

  /// The poll composer, then the send (spec 2026-11-08-chat-extras).
  Future<void> _createPoll(BuildContext context) async {
    final controller = context.read<ChatController>();
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final poll = await showPollComposer(context);
    if (poll == null) return;
    var sent = false;
    try {
      sent = await controller.sendPoll(poll);
    } catch (_) {}
    if (!sent) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.pollSendFailed)));
    }
  }

  /// A tap on a poll option: sends the new full set of picks.
  Future<void> _vote(
    BuildContext context,
    ChatController controller,
    Message message,
    List<int> options,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (!await controller.vote(message.id, options)) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.pollVoteFailed)));
    }
  }

  /// Pin or unpin; at the cap the user confirms that the oldest pin goes.
  Future<void> _togglePin(
    BuildContext context,
    ChatController controller,
    Message message,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final pin = !controller.isPinned(message.id);
    if (pin && controller.pinReplacesOldest(message.id)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.chatPinReplaceTitle),
          content: Text(l10n.chatPinReplaceBody(maxPinsPerConversation)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.chatMessagePin),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!await controller.setPinned(message.id, pin)) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.chatPinFailed)));
    }
  }

  /// Opens the in-chat search; a tapped hit comes back as its message id.
  Future<void> _searchInChat(
    BuildContext context,
    ChatController controller,
  ) async {
    final messageId = await context.push<String>('/chats/$contactId/search');
    if (messageId != null) controller.jumpTo(messageId);
  }

  /// Lists the other chats; picking one opens it and the route sends the
  /// message there (see `ForwardDraft`).
  Future<void> _forward(
    BuildContext context,
    Message message, {
    required ChatController controller,
    required List<Contact> contacts,
  }) async {
    final conversations = context
        .read<ChatListController>()
        .conversations
        .toList();
    final l10n = context.l10n;
    final target = await showDialog<Conversation>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.chatForwardTitle),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: conversations.length,
            itemBuilder: (context, index) {
              final row = conversations[index];
              final matches = contacts.where((c) => c.deviceId == row.id);
              final contact = matches.isEmpty ? null : matches.first;
              final title =
                  row.title ??
                  contact?.displayName ??
                  contact?.userHandle ??
                  row.id;
              return ListTile(
                leading: LetterAvatar(name: title),
                title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(dialogContext).pop(row),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    final body = message.body ?? '';
    if (target.id == controller.conversationId) {
      // Already here: a second controller/route for this chat is not needed.
      await controller.sendForwarded(body: body, type: message.type);
    } else {
      context.push(
        '/chats/${target.id}',
        extra: ForwardDraft(body: body, type: message.type),
      );
    }
  }

  List<MessageAction> _actions(
    BuildContext context,
    ChatController controller,
    Message message, {
    required bool mine,
    required bool business,
    required List<Contact> contacts,
    bool group = false,
    ParticipantColors? colors,
  }) {
    final l10n = context.l10n;
    final isMedia = message.type == 'media';
    final isPoll = message.type == pollMessageType;
    // A media body is JSON with the key: never copied to the clipboard; a
    // poll body is JSON too.
    final isFile = message.type == 'file' || isMedia || isPoll;
    final pending = message.status == 'sending' || message.status == 'failed';
    final mediaInfo = isMedia ? MediaInfo.tryDecode(message.body) : null;
    final delete = MessageAction(
      icon: Icons.delete_outline_rounded,
      label: l10n.chatMessageDelete,
      destructive: true,
      onSelected: () => _delete(
        context,
        controller,
        message,
        canDeleteForEveryone:
            mine && !pending && !business && !message.deleted,
      ),
    );
    if (message.deleted) return [delete];
    final copy = MessageAction(
      icon: Icons.copy_rounded,
      label: l10n.chatMessageCopy,
      onSelected: () => _copy(context, message.body ?? ''),
    );
    if (pending) return [if (!isFile) copy, delete];
    return [
      if (controller.canEdit(message, business: business))
        MessageAction(
          icon: Icons.edit_outlined,
          label: l10n.chatMessageEdit,
          onSelected: () => _edit(context, controller, message),
        ),
      MessageAction(
        icon: Icons.reply_rounded,
        label: l10n.chatMessageReply,
        onSelected: () => controller.startReply(message),
      ),
      if (controller.canPin(message, business: business))
        controller.isPinned(message.id)
            ? MessageAction(
                icon: Icons.push_pin_outlined,
                label: l10n.chatMessageUnpin,
                onSelected: () => _togglePin(context, controller, message),
              )
            : MessageAction(
                icon: Icons.push_pin_outlined,
                label: l10n.chatMessagePin,
                onSelected: () => _togglePin(context, controller, message),
              ),
      if (!isFile) copy,
      // Save to device for every downloaded media message (contract M10).
      if (mediaInfo != null &&
          !mediaInfo.isDraft &&
          controller.media.isLocal(mediaInfo) == true)
        MessageAction(
          icon: Icons.save_alt_rounded,
          label: l10n.mediaSaveToDevice,
          onSelected: () =>
              saveMediaToDevice(context, mediaInfo, controller.media),
        ),
      // Forwarding re-sends the same `media` object, which only works while
      // the server copy lives; after expiry the action is hidden (contract
      // section 3, the app branch's choice).
      // A poll is not forwarded: its votes belong to this conversation.
      if (!isPoll &&
          (!isMedia ||
              (mediaInfo != null &&
                  !mediaInfo.isDraft &&
                  !mediaInfo.isExpired(DateTime.now()))))
        MessageAction(
          icon: Icons.forward_rounded,
          label: l10n.chatMessageForward,
          onSelected: () => _forward(
            context,
            message,
            controller: controller,
            contacts: contacts,
          ),
        ),
      // Spec 2026-11-09-participant-colors D7 b: another member's color.
      if (group && !mine && colors != null)
        MessageAction(
          icon: Icons.palette_outlined,
          label: l10n.participantColorAction,
          onSelected: () => _pickParticipantColor(
            context,
            colors,
            controller,
            message.senderId,
            contacts,
          ),
        ),
      delete,
    ];
  }

  /// Decoded attachments by message id. Decoding base64 on every rebuild
  /// would also hand Image.memory a new byte list each time, which restarts
  /// the image decode and makes thumbnails flicker while the list scrolls.
  static final _attachments = <String, (int, Attachment?)>{};
  static const _attachmentCacheSize = 64;

  static Attachment? _attachmentOf(Message message) {
    final body = message.body ?? '';
    final cached = _attachments[message.id];
    if (cached != null && cached.$1 == body.length) return cached.$2;
    Attachment? attachment;
    try {
      attachment = Attachment.decode(body);
    } catch (_) {}
    if (_attachments.length >= _attachmentCacheSize) {
      _attachments.remove(_attachments.keys.first);
    }
    _attachments[message.id] = (body.length, attachment);
    return attachment;
  }

  /// One row of the message list: a call log line, a device notice, or a
  /// bubble with the sender label (groups) and the delivery status (own).
  Widget _messageRow(
    BuildContext context,
    ChatController controller,
    Message message, {
    required bool group,
    required bool business,
    required List<Contact> allContacts,
  }) {
    final l10n = context.l10n;
    final mine = message.senderId == controller.myIdentityId;
    if (message.type == 'call-event') {
      return _CallEventLine(body: message.body ?? '');
    }
    if (message.type == 'device-change') {
      return _DeviceChangeLine(body: message.body ?? '');
    }
    final file = message.type == 'file' && !message.deleted
        ? _attachmentOf(message)
        : null;
    final canReact = controller.canReact(
      message,
      business: business,
    );
    final mediaInfo =
        message.type == 'media' && !message.deleted
        ? MediaInfo.tryDecode(message.body)
        : null;
    final pollResults = controller.pollResultsOf(message);
    final colors = Theme.of(context).colorScheme;
    // Spec 2026-11-09-participant-colors: other members of a group get
    // their color on the label, the outline and in quotes; 1:1 chats and my
    // own bubbles stay as they were (D1, D2, D8).
    final participantColors = group
        ? maybeParticipantColors(context)
        : null;
    final senderColor = group && !mine
        ? participantColorOf(
            context,
            _personKey(controller, message.senderId, allContacts),
            participantColors,
          )
        : null;
    final replySenderId = message.replySenderId;
    final quoteAccent =
        group &&
            replySenderId != null &&
            replySenderId != controller.myIdentityId
        ? participantColorOf(
            context,
            _personKey(controller, replySenderId, allContacts),
            participantColors,
          )
        : null;
    final senderName = senderLabel(
      message.senderId,
      members: controller.groupMembers,
      contacts: allContacts,
    );
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: senderColor,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (group && !mine)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            // D7 a: a tap on the name opens the color picker. The name
            // stays as text, so color is never the only cue (D12).
            child: participantColors == null
                ? Text(senderName, style: labelStyle)
                : InkWell(
                    key: ValueKey('participant-label:${message.id}'),
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _pickParticipantColor(
                      context,
                      participantColors,
                      controller,
                      message.senderId,
                      allContacts,
                    ),
                    child: Text(senderName, style: labelStyle),
                  ),
          ),
        MessageBubble(
          outlineColor: senderColor,
          quoteAccent: quoteAccent,
          text: message.body ?? '',
          time: DateFormat.Hm(l10n.localeName).format(
            message.createdAt.toLocal(),
          ),
          isMine: mine,
          deleted: message.deleted,
          forwarded: message.forwarded,
          edited: message.editedAt != null,
          // Only under a RECEIVED message of a bot: a human
          // (or this user's own copy) never gets buttons.
          buttons: !mine &&
                  isBotSender(
                    message.senderId,
                    members: controller.groupMembers,
                    contacts: allContacts,
                  )
              ? decodeActionsJson(message.actionsJson)
              : const [],
          onButton: (button) =>
              controller.sendAction(message, button),
          quoteAuthor: message.replySenderId == null
              ? null
              : _authorLabel(
                  context,
                  controller,
                  message.replySenderId!,
                  allContacts,
                ),
          quoteText: message.replyPreview,
          content: pollResults != null
              ? PollCard(
                  results: pollResults,
                  textColor: mine
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                  onVote: controller.canVote(message, business: business)
                      ? (options) =>
                            _vote(context, controller, message, options)
                      : null,
                  onShowVoters: () => showPollVotersSheet(
                    context,
                    results: pollResults,
                    nameOf: (id) =>
                        _authorLabel(context, controller, id, allContacts),
                  ),
                )
              : mediaInfo != null
              ? MediaMessageContent(
                  messageId: message.id,
                  info: mediaInfo,
                  media: controller.media,
                  sending: mine && message.status == 'sending',
                  onCancelUpload: () =>
                      controller.cancelMediaUpload(message.id),
                )
              : file == null
              ? null
              : _attachmentContent(context, file),
          caption: file?.caption,
          reactions: controller.reactionsOf(message.id),
          myReaction: controller.myReactionOf(message.id),
          onReact: canReact
              ? (emoji) => _react(
                  context,
                  controller,
                  message,
                  emoji,
                )
              : null,
          // Own chip: remove; any other: who reacted.
          onReactionTap: (chip) => chip.mine && canReact
              ? _react(
                  context,
                  controller,
                  message,
                  chip.emoji,
                )
              : _showReactors(
                  context,
                  controller,
                  message,
                  contacts: allContacts,
                  canReact: canReact,
                ),
          onReactionLongPress: (_) => _showReactors(
            context,
            controller,
            message,
            contacts: allContacts,
            canReact: canReact,
          ),
          actions: _actions(
            context,
            controller,
            message,
            mine: mine,
            business: business,
            contacts: allContacts,
            group: group,
            colors: participantColors,
          ),
        ),
        if (mine)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            child:
                message.status == 'failed' ||
                    message.status == 'sending'
                ? TextButton(
                    onPressed: () =>
                        controller.retryMessage(message.id),
                    // A failed message that is still resent automatically
                    // shows as sending (spec auto-resend R8).
                    child: Text(
                      message.status == 'failed' &&
                              !controller.retryPending(message)
                          ? l10n.chatStatusFailedRetry
                          : l10n.chatStatusSendingRetry,
                    ),
                  )
                : Text(
                    l10n.chatStatusSent,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall,
                  ),
          ),
      ],
    );
  }

  Widget _attachmentContent(BuildContext context, Attachment file) {
    final download = OutlinedButton.icon(
      onPressed: () => saveAttachment(context, file),
      icon: const Icon(Icons.download),
      label: Text(
        context.l10n.chatAttachmentLabel(
          file.name,
          context.l10n.sizeBytes(file.bytes.length),
        ),
      ),
    );
    // Only names that claim to be an image are tried; the thumbnail itself
    // falls back to the download button when the bytes do not decode.
    return isImageAttachmentName(file.name)
        ? ImageAttachmentThumbnail(attachment: file, fallback: download)
        : download;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatController>();
    final contactsController = context.watch<ContactsController>();
    final allContacts = contactsController.contacts;
    final contacts = allContacts.where((c) => c.deviceId == contactId);
    final conversations = context
        .watch<ChatListController>()
        .conversations
        .where((c) => c.id == contactId);
    final conversation = conversations.isEmpty ? null : conversations.first;
    final group = conversation?.type == 'group';
    final contact = contacts.isEmpty ? null : contacts.first;
    // A 1:1 peer that is not a contact yet: its public profile instead of the
    // raw device id (spec 2026-11-09-contacts-from-replies, C4).
    final peer = group || contact != null || conversation?.title != null
        ? null
        : contactsController.peerProfile(contactId);
    final name =
        conversation?.title ??
        contact?.displayName ??
        contact?.userHandle ??
        peer?.label ??
        contactId;
    final isBot = contact?.isBot ?? peer?.isBot ?? false;
    // Bots whose "/" commands this chat offers: the 1:1 bot, or the group's
    // bot members (by profile or by the local contact flag).
    final commandBots = <CommandBot>[
      if (!group && isBot)
        CommandBot(
          deviceId: contactId,
          handle: contact?.userHandle,
          name: contact?.displayName,
        ),
      if (group)
        for (final m in controller.groupMembers)
          if (m.deviceId != controller.myIdentityId &&
              isBotSender(
                m.deviceId,
                members: controller.groupMembers,
                contacts: allContacts,
              ))
            CommandBot(
              deviceId: m.deviceId,
              handle: m.userHandle,
              name: m.displayName,
            ),
    ];
    final organizationName = conversation?.organizationName;
    final canDelete = context.watch<ChatDeletionService?>() != null;
    final l10n = context.l10n;
    // The sender's language for media fallback texts and quotes.
    controller.localizations = l10n;
    if (controller.consumeAuditRecipientMissing()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.hubErrorAuditRecipientMissing)),
        );
      });
    }
    if (controller.consumeAuditorUnavailable()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.hubErrorAuditorUnavailable)),
        );
      });
    }
    if (controller.consumeBusinessConversationRequired()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        // P1: a redirect, not a retry — offer to open/create the business
        // conversation with this contact instead of silently rerouting the
        // message the user already typed.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.hubErrorBusinessConversationRequired),
            // A companion never takes part in business conversations, so it
            // gets the explanation only; the primary does the redirect.
            action: controller.isCompanion
                ? null
                : SnackBarAction(
                    label: l10n.hubErrorBusinessConversationRequiredAction,
                    onPressed: () async {
                      final groupId = await controller
                          .createBusinessConversationWithPeer();
                      if (groupId != null && context.mounted) {
                        context.go('/chats/$groupId');
                      }
                    },
                  ),
          ),
        );
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: group
            ? GroupHeaderTitle(
                conversationId: contactId,
                name: name,
                topic: controller.groupTopic,
              )
            : NameWithBotBadge(name: name, isBot: isBot),
        actions: [
          // A bot is a headless program with no WebRTC stack — a call could
          // only ever ring out, so the buttons are not offered at all.
          // v1: calls ring the primary only, so a companion offers none
          // (spec "Limits of v1").
          if (!group && !isBot && !controller.isCompanion) ...[
            IconButton(
              icon: const Icon(Icons.call_rounded),
              tooltip: l10n.chatVoiceCall,
              onPressed: () => _call(context, false),
            ),
            IconButton(
              icon: const Icon(Icons.videocam_rounded),
              tooltip: l10n.chatVideoCall,
              onPressed: () => _call(context, true),
            ),
          ],
          // A business "1:1" is a GROUP (the two members plus the visible
          // auditor) — offer call buttons only when there is exactly one
          // other non-auditor member; a larger group has no group calls.
          if (group && organizationName != null && !controller.isCompanion)
            FutureBuilder<String?>(
              future: controller.businessCallTarget(),
              builder: (context, snapshot) {
                final peer = snapshot.data;
                if (peer == null) return const SizedBox.shrink();
                return Row(children: [
                  IconButton(
                    icon: const Icon(Icons.call_rounded),
                    tooltip: l10n.chatVoiceCall,
                    onPressed: () => _call(
                      context,
                      false,
                      targetDeviceId: peer,
                      businessGroupId: contactId,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.videocam_rounded),
                    tooltip: l10n.chatVideoCall,
                    onPressed: () => _call(
                      context,
                      true,
                      targetDeviceId: peer,
                      businessGroupId: contactId,
                    ),
                  ),
                ]);
              },
            ),
          IconButton(
            key: const ValueKey('chat-search'),
            icon: const Icon(Icons.search_rounded),
            tooltip: l10n.searchInChatTooltip,
            onPressed: () => _searchInChat(context, controller),
          ),
          // Group ids and 1:1 ids (the peer's identity) are both the
          // conversation id, so one button serves both kinds of chat.
          MuteButton(conversationId: contactId, group: group),
          if (group)
            PopupMenuButton<void>(
              key: const ValueKey('chat-group-menu'),
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: const ValueKey('chat-group-info'),
                  onTap: () => context.push('/chats/$contactId/info'),
                  child: Text(l10n.groupInfoTitle),
                ),
                PopupMenuItem(
                  onTap: () => context.push('/chats/$contactId/bot-talk'),
                  child: Text(l10n.botTalkTitle),
                ),
                // T6 (spec 2026-11-13-group-topics row 16): not in business
                // groups, and groups are created from the primary only.
                if (organizationName == null && !controller.isCompanion)
                  PopupMenuItem(
                    key: const ValueKey('chat-new-topic'),
                    onTap: () =>
                        context.push('/groups/create?from=$contactId'),
                    child: Text(l10n.groupNewTopicWithMembers),
                  ),
                // Spec 2026-11-09-delete-chats-contacts D1/D5 (there is no
                // separate group detail screen, so they live here).
                if (canDelete) ...[
                  PopupMenuItem(
                    key: const ValueKey('chat-delete'),
                    onTap: () => _deleteChat(context, group: true),
                    child: Text(l10n.chatDeleteChat),
                  ),
                  PopupMenuItem(
                    key: const ValueKey('chat-leave-group'),
                    onTap: () => _leaveGroup(context),
                    child: Text(l10n.chatLeaveGroup),
                  ),
                ],
              ],
            ),
          // Every direct chat can be renamed (C3); for a peer that is not a
          // contact yet, Rename adds it first and "Add contact" adds it
          // without renaming.
          if (!group)
            PopupMenuButton<void>(
              key: const ValueKey('chat-direct-menu'),
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: const ValueKey('chat-rename'),
                  onTap: () => contact != null
                      ? showRenameContactDialog(context, contact)
                      : showRenamePeerDialog(context, contactId),
                  child: Text(l10n.contactRename),
                ),
                if (contact == null)
                  PopupMenuItem(
                    key: const ValueKey('chat-add-contact'),
                    onTap: () => addPeerToContacts(context, contactId),
                    child: Text(l10n.contactsAddContact),
                  ),
                // Spec 2026-11-09-delete-chats-contacts D1/D4/D7.
                if (canDelete)
                  PopupMenuItem(
                    key: const ValueKey('chat-delete'),
                    onTap: () => _deleteChat(context, group: false),
                    child: Text(l10n.chatDeleteChat),
                  ),
                if (contact != null)
                  PopupMenuItem(
                    key: const ValueKey('chat-delete-contact'),
                    onTap: () => _deleteContact(context, contact, name),
                    child: Text(l10n.contactDelete),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (!context.watch<SignalRClient>().connected)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l10n.chatOffline),
            ),
          if (isBot) _BotNotice(contactId: contactId),
          // Business mode (Jay, KB1): permanent, non-dismissable — see
          // BusinessBanner's doc for why there is no close action.
          if (organizationName != null) ...[
            BusinessBanner(organizationName: organizationName),
            AuditorMemberTile(organizationName: organizationName),
          ],
          PinnedMessageBar(
            pins: controller.pinnedMessages,
            previewOf: (message) =>
                ChatController.replyPreviewOf(message, l10n),
            onJump: (message) => controller.jumpTo(message.id),
            onShowAll: () => showPinnedMessagesSheet(
              context,
              pins: controller.pinnedMessages,
              previewOf: (message) =>
                  ChatController.replyPreviewOf(message, l10n),
              authorOf: (message) => _authorLabel(
                context,
                controller,
                message.senderId,
                allContacts,
              ),
              onJump: (message) => controller.jumpTo(message.id),
              onUnpin: conversation?.organizationId != null
                  ? null
                  : (message) => _togglePin(context, controller, message),
            ),
          ),
          Expanded(
            child: controller.messages.isEmpty
                ? Center(child: Text(l10n.chatEmpty))
                : ChatMessageList<Message>(
                    items: controller.messages,
                    jumpRequest: controller.jumpRequest,
                    idOf: (message) => message.id,
                    isMine: (message) =>
                        message.senderId == controller.myIdentityId,
                    itemBuilder: (context, message) => _messageRow(
                      context,
                      controller,
                      message,
                      group: group,
                      business: conversation?.organizationId != null,
                      allContacts: allContacts,
                    ),
                  ),
          ),
          // v1: business conversations stay on the primary (KB2 auditor rules
          // are defined over member devices). A companion says why it cannot
          // write here instead of failing on send.
          if (organizationName != null && controller.isCompanion)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.chatCompanionBusinessReadOnly,
                textAlign: TextAlign.center,
              ),
            )
          else
            MessageInput(
              // A new conversation is a new composer with its own draft.
              key: ValueKey('composer:$contactId'),
              loadDraft: controller.loadDraft,
              saveDraft: controller.saveDraft,
              onSend: controller.sendMessage,
              onSendWithMentions: (text, mentions) =>
                  controller.sendMessage(text, mentions: mentions),
              commandSuggestions: commandBots.isEmpty
                  ? null
                  : () => controller.commandSuggestions(
                      commandBots,
                      group: group,
                    ),
              initialText: controller.initialDraft,
              onAttachment: () =>
                  _attach(
                context,
                business: conversation?.organizationId != null,
              ),
              // No voice messages in business conversations (no media).
              onVoice: conversation?.organizationId != null
                  ? null
                  : (clip) => _sendVoice(controller, clip),
              replyAuthor: controller.replyingTo == null
                  ? null
                  : _authorLabel(
                      context,
                      controller,
                      controller.replyingTo!.senderId,
                      allContacts,
                    ),
              replyText: controller.replyingTo == null
                  ? null
                  : ChatController.replyPreviewOf(controller.replyingTo!),
              onCancelReply: controller.cancelReply,
              mentionCandidates: group
                  ? buildMentionCandidates(
                      members: controller.groupMembers,
                      contacts: allContacts,
                      myIdentityId: controller.myIdentityId,
                    )
                  : const [],
            ),
        ],
      ),
    );
  }
}
