import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'onboarding_controller.dart';

/// First-run screen that registers the device with the server and shows
/// the user's identity (handle + QR code) for contact exchange.
///
/// The screen has three visual states:
/// 1. **Initial** — brand splash with "Get Started" button.
/// 2. **Loading** — progress indicator while the registration API call runs.
/// 3. **Success** — user handle, QR code, and "Start Messaging" button.
/// 4. **Error** — error message with retry option.
///
/// Uses [OnboardingController] via Provider for state management.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
                    width: 96,
                    height: 96,
                    semanticLabel: 'Jay',
                  ),
                ),
                const SizedBox(height: 24),

                Text(
                  'Jay',
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),

                Text(
                  'Secure. Anonymous. Simple.',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 48),

                // -- Dynamic content based on controller state -----------------
                if (controller.isLoading) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    'Setting up your device...',
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
                  // Initial state — user hasn't started registration yet.
                  FilledButton.icon(
                    onPressed: controller.register,
                    icon: const Icon(Icons.rocket_launch_rounded),
                    label: const Text('Get Started'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
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
        Text('Your Identity', style: theme.textTheme.titleMedium),
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
          'Share this QR code to add contacts',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),

        FilledButton.icon(
          onPressed: () => context.go('/chats'),
          icon: const Icon(Icons.chat_rounded),
          label: const Text('Start Messaging'),
        ),
      ],
    );
  }
}

/// Error display with retry button.
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
              'Registration failed',
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
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
