import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/network/webrtc_manager.dart';

/// Main settings screen with navigation to sub-settings.
///
/// Organized into sections:
///   - Security: App Lock (PIN + biometrics)
///   - Account: Registration, login, multi-device
///   - Data: Cloud backup
///   - Identity: Contact invite and QR code
///   - About: Version info
///
/// Each row navigates to a dedicated sub-screen. The settings screen itself
/// has no state — it's purely a navigation hub.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // -- Security section ------------------------------------------------
          _SettingsTile(
            icon: Icons.lock_rounded,
            iconColor: colorScheme.primary,
            title: 'App Lock',
            subtitle: 'PIN and biometric authentication',
            onTap: () => context.push('/settings/lock'),
          ),

          // -- Account section ------------------------------------------------
          _SettingsTile(
            icon: Icons.person_rounded,
            iconColor: colorScheme.primary,
            title: 'Account',
            subtitle: 'Register or log in for cloud features',
            onTap: () => context.push('/settings/account'),
          ),

          // -- Data section ---------------------------------------------------
          _SettingsTile(
            icon: Icons.cloud_upload_rounded,
            iconColor: colorScheme.primary,
            title: 'Backup',
            subtitle: 'Encrypted cloud backup',
            onTap: () => context.push('/settings/backup'),
          ),

          // -- Devices section ------------------------------------------------
          _SettingsTile(
            icon: Icons.devices_rounded,
            iconColor: colorScheme.primary,
            title: 'My identity',
            subtitle: 'Share your contact invite and QR code',
            onTap: () => context.push('/settings/identity'),
          ),

          // -- Channels section -----------------------------------------------
          // Blocking a channel is local to this device, so the only place
          // to undo it has to be reachable without the (blocked) channel.
          _SettingsTile(
            icon: Icons.block_rounded,
            iconColor: colorScheme.primary,
            title: 'Blocked channels',
            subtitle: 'Review and unblock channels',
            onTap: () => context.push('/channels/blocked'),
          ),

          const Divider(indent: 16, endIndent: 16),

          // -- Diagnostics section --------------------------------------------
          // Beta acceptance needs proof that calls really work through the
          // TURN relay (not just direct P2P). This forces relay-only ICE for
          // the next calls; it is in-memory and resets on app restart.
          SwitchListTile(
            secondary: Icon(Icons.alt_route_rounded, color: colorScheme.tertiary),
            title: const Text('Force TURN relay (diagnostics)'),
            subtitle: const Text(
              'Next calls use the relay only. Slower; resets on restart.',
            ),
            value: context.watch<WebRTCManager>().forceIceRelay,
            onChanged: context.read<WebRTCManager>().setForceIceRelay,
          ),

          const Divider(indent: 16, endIndent: 16),

          // -- About section --------------------------------------------------
          // Version is hardcoded here to match pubspec.yaml. In production,
          // use package_info_plus to read the version dynamically.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: Text(
                'Jay 1.0.0 beta',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable list tile for settings navigation rows.
///
/// Provides a consistent look: leading colored icon, title + subtitle,
/// and a trailing chevron to indicate navigation.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}
