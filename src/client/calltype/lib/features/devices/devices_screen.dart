import 'dart:async';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../contacts/qr_scanner_screen.dart';
import 'device_service.dart';
import 'link_controllers.dart';

/// Settings > Linked devices. On the primary: its companions, removal and
/// "Link a device". On a companion: whose device it is; the list is managed
/// on the primary, the only device that can sign it.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  // The contact scanner has the same gap: no camera plugin on these.
  static bool get _hasCamera =>
      kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.windows &&
          defaultTargetPlatform != TargetPlatform.linux);

  Future<(List<DeviceListEntry>, bool)> _load(
    AppDatabase db,
    DeviceService devices,
  ) async => (await devices.companions(), await isEmptyDevice(db));

  @override
  Widget build(BuildContext context) {
    final devices = context.watch<DeviceService>();
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsDevices)),
      body: devices.isCompanion
          ? FutureBuilder<String?>(
              future: devices.linkedPrimaryHandle(),
              builder: (context, snapshot) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.devicesLinkedTo(
                    snapshot.data ?? devices.directory.selfIdentityId,
                  ),
                ),
              ),
            )
          : FutureBuilder<(List<DeviceListEntry>, bool)>(
              future: _load(context.read<AppDatabase>(), devices),
              builder: (context, snapshot) {
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final (companions, empty) = data;
                return ListView(
                  children: [
                    if (companions.isEmpty) ListTile(title: Text(l10n.devicesEmpty)),
                    // The server claims these no longer exist. Re-signing the
                    // list on its word alone would let a lying server get a
                    // healthy companion wiped, so the user decides.
                    for (final id in devices.vanishedCompanions)
                      ListTile(
                        leading: const Icon(Icons.warning_amber_rounded),
                        title: Text(
                          l10n.devicesVanishedPrompt(
                            l10n.devicesDeviceLabel(id.substring(0, 8)),
                          ),
                        ),
                        subtitle: Wrap(
                          children: [
                            TextButton(
                              onPressed: () => _confirmVanished(context, id),
                              child: Text(l10n.devicesRemove),
                            ),
                            TextButton(
                              onPressed: devices.dismissVanished,
                              child: Text(l10n.devicesKeep),
                            ),
                          ],
                        ),
                      ),
                    for (final device in companions)
                      ListTile(
                        leading: const Icon(Icons.devices_other_rounded),
                        title: Text(
                          l10n.devicesDeviceLabel(device.deviceId.substring(0, 8)),
                        ),
                        trailing: TextButton(
                          onPressed: () => _remove(context, device.deviceId),
                          child: Text(l10n.devicesRemove),
                        ),
                      ),
                    if (_hasCamera && companions.length < maxCompanionDevices)
                      ListTile(
                        leading: const Icon(Icons.qr_code_scanner_rounded),
                        title: Text(l10n.devicesAdd),
                        onTap: () => _add(context),
                      ),
                    // Decision 3: only an empty device may become a companion,
                    // and a device that already has companions is a primary.
                    if (empty && companions.isEmpty)
                      ListTile(
                        leading: const Icon(Icons.link_rounded),
                        title: Text(l10n.linkDeviceAction),
                        onTap: () => context.push('/settings/devices/link'),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Future<void> _confirmVanished(BuildContext context, String id) async {
    final l10n = context.l10n;
    final devices = context.read<DeviceService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await devices.confirmRemoveVanished(ids: [id]);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.devicesRemoveFailed)));
    }
  }

  Future<void> _remove(BuildContext context, String deviceId) async {
    final l10n = context.l10n;
    final devices = context.read<DeviceService>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.devicesRemoveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.devicesRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await devices.removeCompanions({deviceId});
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.devicesRemoveFailed)));
    }
  }

  Future<void> _add(BuildContext context) async {
    final devices = context.read<DeviceService>();
    final api = context.read<ApiClient>();
    final signalR = context.read<SignalRClient>();
    final storage = context.read<SecureStorage>();
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen(deviceLink: true)),
    );
    final scanned = result?['link'];
    if (scanned == null || !context.mounted) return;
    // Our own handle, shown while waiting so the user can compare it with
    // what the new device displays (a forged offer would show another one).
    final handle =
        await storage.read('ct_user_handle') ?? devices.directory.selfDeviceId;
    if (!context.mounted) return;
    final controller = PrimaryLinkController(
      devices: devices,
      apiClient: api,
      signalRClient: signalR,
    );
    unawaited(controller.link(scanned));
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: PrimaryLinkDialog(handle: handle),
      ),
    );
    controller.dispose();
  }
}

/// Progress of the primary's linking. Closing it cancels the link: a consent
/// arriving afterwards must not sign anything the user walked away from.
class PrimaryLinkDialog extends StatelessWidget {
  const PrimaryLinkDialog({super.key, required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PrimaryLinkController>().state;
    final l10n = context.l10n;
    final message = switch (state) {
      PrimaryLinkState.waitingForConsent => l10n.devicesWaitingConsent(handle),
      PrimaryLinkState.mismatch => l10n.devicesFingerprintMismatch,
      PrimaryLinkState.failed => l10n.devicesLinkFailed,
      _ => null,
    };
    final busy =
        state == PrimaryLinkState.idle ||
        state == PrimaryLinkState.working ||
        state == PrimaryLinkState.waitingForConsent;
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const CircularProgressIndicator()
          else
            Icon(
              state == PrimaryLinkState.linked
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              size: 48,
            ),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            context.read<PrimaryLinkController>().cancel();
            Navigator.of(context).pop();
          },
          // Built-in and localized in every Flutter language.
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
