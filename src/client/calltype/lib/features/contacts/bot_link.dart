import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../chat/chat_controller.dart' show ComposerDraft;
import '../chat_list/chat_list_controller.dart';
import 'contacts_controller.dart';
import 'contacts_screen.dart' show previewAndAddContact;

/// `calltype://bot/<HANDLE>?start=<payload>` (agent messaging contract,
/// sections 5 and 8; the bot runtime builds it with `CallTypeBot.deepLink`).
class BotLink {
  const BotLink({required this.handle, this.start});

  /// Upper-cased like every handle lookup.
  final String handle;

  /// The `start` payload, or null when absent or invalid.
  final String? start;

  /// What the composer is pre-filled with.
  String get startCommand => start == null ? '/start' : '/start $start';
}

const botLinkPrefix = 'calltype://bot/';

/// The app route of [link] (see `/bot/:handle` in lib/app/router.dart).
String botLinkRoute(BotLink link) => link.start == null
    ? '/bot/${link.handle}'
    : '/bot/${link.handle}?start=${link.start}';

/// Same rule as the bot runtime: 1..64 of `[A-Za-z0-9_-]`.
final _startPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Handles are `CT-XXXX-XXXX`; kept a little looser (letters, digits,
/// dashes) so a future handle shape still opens, while anything that could
/// smuggle a path or query into the route is refused.
final _handlePattern = RegExp(r'^[A-Z0-9][A-Z0-9-]{0,63}$');

/// Parses a bot deep link, or null when [raw] is not one (or names no valid
/// handle). An invalid `start` is IGNORED, not fatal: the link still opens
/// the bot, just without a payload (contract: "ignore invalid").
BotLink? parseBotLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme.toLowerCase() != 'calltype' ||
      uri.host.toLowerCase() != 'bot' ||
      uri.pathSegments.length != 1) {
    return null;
  }
  final handle = uri.pathSegments.single.toUpperCase();
  if (!_handlePattern.hasMatch(handle)) return null;
  final start = uri.queryParameters['start'];
  return BotLink(
    handle: handle,
    start: start != null && _startPattern.hasMatch(start) ? start : null,
  );
}

/// Opens the bot of a deep link: an existing contact directly, otherwise
/// through the normal add-contact confirmation (which shows the bot badge
/// and notice). Then opens the chat with `/start <payload>` in the composer.
///
/// WHY never auto-send: a link is untrusted input; sending would let any web
/// page make the user message a bot of its choice with a payload of its
/// choice. The user sees the text and presses send (design D4).
class BotLinkScreen extends StatefulWidget {
  const BotLinkScreen({super.key, required this.link});
  final BotLink link;

  @override
  State<BotLinkScreen> createState() => _BotLinkScreenState();
}

class _BotLinkScreenState extends State<BotLinkScreen> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: the confirmation is a dialog, which needs a
    // laid-out navigator.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final contacts = context.read<ContactsController>();
    final chats = context.read<ChatListController>();
    try {
      await contacts.loadContacts();
      final existing = contacts.contacts
          .where((c) => c.userHandle.toUpperCase() == widget.link.handle)
          .firstOrNull;
      String? deviceId = existing?.deviceId;
      if (deviceId == null) {
        if (!mounted) return;
        final added = await previewAndAddContact(
          context,
          contacts,
          widget.link.handle,
        );
        if (added == null) {
          // Declined: back to the app, nothing was added or written.
          if (mounted) context.go('/chats');
          return;
        }
        deviceId = added.deviceId;
      }
      await chats.createDirectConversation(deviceId);
      if (!mounted) return;
      context.go(
        '/chats/$deviceId',
        extra: ComposerDraft(widget.link.startCommand),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(widget.link.handle)),
      body: Center(
        child: _failed
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.botLinkFailed, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() => _failed = false);
                        _open();
                      },
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
