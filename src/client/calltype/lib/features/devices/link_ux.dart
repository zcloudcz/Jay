import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import 'device_service.dart';

// Link UX (docs/superpowers/specs/2026-11-06-link-ux.md): the pieces the
// onboarding, the chat list, settings and the account screen share. The
// security model is the one of spec 1 and does not change here: only the
// phone scanning this device's QR code adds it to the signed list.

/// Web and desktop lead the first run with "use Jay from your phone", like
/// WhatsApp Web: people open the web expecting their phone's chats, and a
/// "Get started" that silently created a second identity sent them the wrong
/// way. Phones keep the old onboarding (a phone is usually the primary).
bool get isLinkFirstPlatform =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Whether this platform can scan another device's link code. Same rule as
/// the contact scanner: Windows and Linux have no camera plugin.
bool get canScanLinkCodes =>
    kIsWeb ||
    (defaultTargetPlatform != TargetPlatform.windows &&
        defaultTargetPlatform != TargetPlatform.linux);

/// SecureStorage key: this device is registered only to be linked and still
/// waits for the phone. While it is set the router keeps the device on the
/// link screen. WHY: the device id is created before the QR code can exist,
/// so without the marker a reload of the page would land in an empty chat
/// list as a brand new identity, the very mistake the link-first screen is
/// there to prevent.
const linkPendingKey = 'ct_link_pending';

/// Where a device waiting to be linked is sent.
const linkFirstRoute = '/onboarding?link=1';

/// Linking finished: the marker goes, then the chat list.
Future<void> finishLink(BuildContext context) async {
  final storage = context.read<SecureStorage>();
  final router = GoRouter.maybeOf(context);
  try {
    await storage.delete(linkPendingKey);
  } catch (_) {
    // The router also drops the marker once the device is a companion.
  }
  router?.go('/chats');
}

enum _DisconnectChoice { backup, confirm }

/// "Disconnect this device and link it with your phone" (link UX, A3).
///
/// Explains what is lost, offers a backup first, and on an explicit
/// confirmation deletes this device's chats, contacts and sessions
/// ([DeviceService.resetForLinking]) and marks the device as waiting for the
/// link. Returns true only when the reset happened; the caller then shows the
/// link code. A primary with companions is refused with an explanation.
Future<bool> confirmDisconnectAndLink(BuildContext context) async {
  final devices = context.read<DeviceService>();
  final storage = context.read<SecureStorage>();
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  Future<void> refuse() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.disconnectAndLinkTitle),
      content: Text(l10n.disconnectAndLinkRefused),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
        ),
      ],
    ),
  );

  // Checked before asking: the user should not confirm a deletion that is
  // then refused.
  if (devices.isCompanion || (await devices.companions()).isNotEmpty) {
    if (context.mounted) await refuse();
    return false;
  }
  if (!context.mounted) return false;
  final choice = await showDialog<_DisconnectChoice>(
    context: context,
    builder: (dialogContext) {
      final colors = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(l10n.disconnectAndLinkTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.disconnectAndLinkWarning),
            const SizedBox(height: 12),
            Text(l10n.disconnectAndLinkBackupHint),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DisconnectChoice.backup),
            child: Text(l10n.disconnectAndLinkBackup),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DisconnectChoice.confirm),
            child: Text(l10n.disconnectAndLinkConfirm),
          ),
        ],
      );
    },
  );
  if (choice == _DisconnectChoice.backup) {
    if (context.mounted) GoRouter.maybeOf(context)?.push('/settings/backup');
    return false;
  }
  if (choice != _DisconnectChoice.confirm) return false;
  try {
    await devices.resetForLinking();
  } on LinkResetRefused {
    if (context.mounted) await refuse();
    return false;
  } catch (_) {
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.disconnectAndLinkFailed)),
    );
    return false;
  }
  try {
    await storage.write(linkPendingKey, '1');
  } catch (_) {
    // Only the reload protection is lost; the link screen still follows.
  }
  return true;
}
