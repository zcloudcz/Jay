import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import 'link_controllers.dart';

/// The new device's side of linking: QR code, the "Link to CT-XXXX-XXXX?"
/// question, then waiting until the primary has signed the list.
class LinkDeviceScreen extends StatelessWidget {
  const LinkDeviceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CompanionLinkController>();
    final l10n = context.l10n;
    if (controller.state == CompanionLinkState.linked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/chats');
      });
    }
    final handle = controller.offeredHandle ?? '';
    final Widget body = switch (controller.state) {
      CompanionLinkState.notEmpty => Text(
        l10n.linkDeviceNotEmpty,
        textAlign: TextAlign.center,
      ),
      CompanionLinkState.showingCode => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: QrImageView(data: controller.code!, size: 240),
          ),
          const SizedBox(height: 24),
          Text(l10n.linkDeviceInstructions, textAlign: TextAlign.center),
        ],
      ),
      // The handle comes from the server's LinkOffer; the user's comparison
      // with the phone in their hand is what catches a forged offer.
      CompanionLinkState.offered => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.linkDeviceConfirmTitle(handle),
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(l10n.linkDeviceConfirmBody(handle), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: controller.reject,
                child: Text(l10n.commonCancel),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: controller.accept,
                child: Text(l10n.linkDeviceConfirm),
              ),
            ],
          ),
        ],
      ),
      CompanionLinkState.waiting => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(l10n.linkDeviceWaiting, textAlign: TextAlign.center),
        ],
      ),
      CompanionLinkState.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.devicesLinkFailed, textAlign: TextAlign.center),
          TextButton(onPressed: controller.reject, child: Text(l10n.commonRetry)),
        ],
      ),
      CompanionLinkState.loading ||
      CompanionLinkState.linked => const CircularProgressIndicator(),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.linkDeviceAction)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: body,
        ),
      ),
    );
  }
}
