import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:calltype_core/crypto/key_manager.dart';
import '../../core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../devices/device_service.dart';
import '../devices/link_controllers.dart';
import '../devices/link_device_screen.dart';
import '../devices/link_ux.dart';
import 'onboarding_controller.dart';

/// First-run screen that registers the device with the server and shows
/// the user's identity (handle + QR code) for contact exchange.
///
/// The screen has these visual states:
/// 1. **Initial** — brand splash with "Get Started" button.
/// 2. **Loading** — progress indicator while the registration API call runs.
/// 3. **Success** — user handle, QR code, and "Start Messaging" button.
/// 4. **Error** — error message with retry option.
///
/// On web and desktop ([linkFirst], link UX A1) it leads with linking
/// instead: "Use Jay from your phone", the link code and three steps, with
/// "start here" as the smaller alternative. The device registers silently
/// for the code, and its own handle is never presented as "your identity".
///
/// Uses [OnboardingController] via Provider for state management.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.linkFirst});

  /// Lead with linking. Defaults to [isLinkFirstPlatform]; the router passes
  /// true for a device that waits to be linked ([linkFirstRoute]), and tests
  /// inject it instead of depending on kIsWeb.
  final bool? linkFirst;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.linkFirst ?? isLinkFirstPlatform) {
      final controller = context.read<OnboardingController>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controller.startLinking();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    // Until the post-frame start runs, a link-first screen must not flash
    // the "Get started" button it replaces.
    final linkMode =
        controller.linkMode ||
        ((widget.linkFirst ?? isLinkFirstPlatform) &&
            controller.userHandle == null &&
            !controller.isLoading &&
            controller.error == null &&
            controller.deviceId == null);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // -- Brand mark ------------------------------------------------
                // The opaque (white-tile) variant is used on purpose: the petrol
                // mark on a transparent background disappears on the dark theme.
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.asset(
                    'assets/brand/jay-icon.png',
                    width: linkMode ? 64 : 96,
                    height: linkMode ? 64 : 96,
                    semanticLabel: 'Jay',
                  ),
                ),
                const SizedBox(height: 24),

                if (linkMode)
                  _LinkFirstContent(controller: controller)
                else ...[
                  Text(
                    'Jay',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Text(
                    l10n.onboardingTagline,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 48),

                  // -- Dynamic content based on controller state ---------------
                  if (controller.isLoading) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      l10n.onboardingSettingUp,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ] else if (controller.error != null) ...[
                    _ErrorCard(
                      error: controller.error!,
                      onRetry: controller.register,
                    ),
                  ] else if (controller.userHandle != null) ...[
                    _SuccessContent(
                      userHandle: controller.userHandle!,
                      qrData: controller.qrData!,
                    ),
                  ] else ...[
                    // Initial state: user has not started registration yet.
                    FilledButton.icon(
                      onPressed: controller.register,
                      icon: const Icon(Icons.rocket_launch_rounded),
                      label: Text(l10n.onboardingGetStarted),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Link-first onboarding (link UX, A1): what this is, the link code with its
/// steps, and the standalone alternative below it.
class _LinkFirstContent extends StatelessWidget {
  const _LinkFirstContent({required this.controller});

  final OnboardingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        children: [
          Text(
            l10n.linkFirstTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.linkFirstBody,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          if (controller.error != null)
            _ErrorCard(
              error: controller.error!,
              onRetry: controller.startLinking,
            )
          else if (controller.deviceId != null)
            const _OnboardingLinkPanel()
          else ...[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.onboardingSettingUp),
          ],
          const SizedBox(height: 32),
          TextButton(
            onPressed: controller.startStandalone,
            child: Text(l10n.linkFirstStandalone, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

/// Owns the [CompanionLinkController] of the link-first onboarding. Built
/// only once the device has an id, which the link code needs.
class _OnboardingLinkPanel extends StatefulWidget {
  const _OnboardingLinkPanel();

  @override
  State<_OnboardingLinkPanel> createState() => _OnboardingLinkPanelState();
}

class _OnboardingLinkPanelState extends State<_OnboardingLinkPanel> {
  late final CompanionLinkController _controller = CompanionLinkController(
    database: context.read<AppDatabase>(),
    devices: context.read<DeviceService>(),
    keyManager: context.read<KeyManager>(),
    signalRClient: context.read<SignalRClient>(),
  );

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: _controller,
    child: const LinkCodeView(),
  );
}

/// Displays the registration result: user handle + QR code.
///
/// The QR code encodes the device ID and user handle so a scanning
/// peer can immediately look up the key bundle and start a session.
class _SuccessContent extends StatelessWidget {
  const _SuccessContent({required this.userHandle, required this.qrData});

  final String userHandle;
  final String qrData;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
        Text(context.l10n.onboardingYourIdentity, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),

        // SelectableText so the user can copy their handle to share
        // via other channels (SMS, email) if QR scanning isn't convenient.
        SelectableText(
          userHandle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 24),

        // QR code for in-person contact exchange — the primary way
        // to add contacts without leaking any metadata to the server.
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 200,
            // Error correction level M balances scanability with data
            // density — our payload is small so M is more than enough.
            errorCorrectionLevel: QrErrorCorrectLevel.M,
          ),
        ),
        const SizedBox(height: 8),

        Text(
          context.l10n.onboardingShareQr,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),

        FilledButton.icon(
          onPressed: () => context.go('/chats'),
          icon: const Icon(Icons.chat_rounded),
          label: Text(context.l10n.onboardingStartMessaging),
        ),
        const SizedBox(height: 12),
        // Right after registration the device is still empty, the only kind
        // of device v1 links as a companion (decision 3).
        OutlinedButton.icon(
          onPressed: () => context.go('/settings/devices/link'),
          icon: const Icon(Icons.link_rounded),
          label: Text(context.l10n.linkDeviceAction),
        ),
      ],
    );
  }
}

/// Error display with retry button.
///
/// The title is localized; the detail line is the raw exception text —
/// developer-facing diagnostics that beta testers screenshot into bug
/// reports, deliberately not translated.
///
/// Shows a condensed error message — the full exception toString() can be
/// verbose, so we limit display to keep the UI clean while still giving
/// the user actionable feedback.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(Icons.error_outline, color: colorScheme.error, size: 32),
            const SizedBox(height: 8),
            Text(
              context.l10n.onboardingFailed,
              style: theme.textTheme.titleSmall?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}
