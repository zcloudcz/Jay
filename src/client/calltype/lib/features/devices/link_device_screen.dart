import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import 'link_controllers.dart';
import 'link_ux.dart';

/// The new device's side of linking: QR code, the "Link to CT-XXXX-XXXX?"
/// question, then waiting until the primary has signed the list.
class LinkDeviceScreen extends StatelessWidget {
  const LinkDeviceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.linkDeviceAction)),
      body: const Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: LinkCodeView(),
        ),
      ),
    );
  }
}

/// The states of [CompanionLinkController] as one widget, shared by
/// [LinkDeviceScreen] and the link-first onboarding (link UX, A1), so both
/// show the same code, steps and questions.
class LinkCodeView extends StatefulWidget {
  const LinkCodeView({super.key});

  @override
  State<LinkCodeView> createState() => _LinkCodeViewState();
}

class _LinkCodeViewState extends State<LinkCodeView> {
  bool _finishing = false;

  Future<void> _disconnect(CompanionLinkController controller) async {
    if (await confirmDisconnectAndLink(context) && mounted) {
      // The device is empty now: the same screen shows its code.
      await controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CompanionLinkController>();
    final l10n = context.l10n;
    if (controller.state == CompanionLinkState.linked && !_finishing) {
      _finishing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) finishLink(context);
      });
    }
    final handle = controller.offeredHandle ?? '';
    return switch (controller.state) {
      CompanionLinkState.notEmpty => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.linkDeviceNotEmpty, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          // Link UX A3: the way out that used to be "open a private window".
          FilledButton.tonalIcon(
            onPressed: () => _disconnect(controller),
            icon: const Icon(Icons.phonelink_erase_rounded),
            label: Text(
              l10n.disconnectAndLinkAction,
              textAlign: TextAlign.center,
            ),
          ),
        ],
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
          const LinkSteps(),
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
          // The only way out if the phone never finishes (it may have timed
          // out or been closed); otherwise the screen would wait for good.
          TextButton(
            onPressed: controller.reject,
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
      CompanionLinkState.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.devicesLinkFailed, textAlign: TextAlign.center),
          TextButton(
            onPressed: controller.reject,
            child: Text(l10n.commonRetry),
          ),
        ],
      ),
      CompanionLinkState.loading ||
      CompanionLinkState.linked => const CircularProgressIndicator(),
    };
  }
}

/// "1. Open Jay on your phone 2. Tap Link web / computer 3. Scan this code".
class LinkSteps extends StatelessWidget {
  const LinkSteps({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final steps = [
      l10n.linkStepOpenPhone,
      l10n.linkStepTapEntry(l10n.linkWebAction),
      l10n.linkStepScan,
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, step) in steps.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(radius: 12, child: Text('${index + 1}')),
                  const SizedBox(width: 12),
                  Expanded(child: Text(step)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
