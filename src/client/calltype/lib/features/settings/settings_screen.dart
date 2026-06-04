import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Main settings screen with navigation to sub-settings.
///
/// Organized into sections:
///   - Security: App Lock (PIN + biometrics)
///   - Account: Registration, login, multi-device
///   - Data: Cloud backup
///   - Devices: Linked devices (placeholder for multi-device sync)
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
            title: 'Linked Devices',
            subtitle: 'Manage your devices',
            onTap: () {
              // Placeholder — multi-device management requires account
              // registration and device linking API (future phase).
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Linked Devices will be available in a future update.'),
                ),
              );
            },
          ),

          const Divider(indent: 16, endIndent: 16),

          // -- About section --------------------------------------------------
          // Version is hardcoded here to match pubspec.yaml. In production,
          // use package_info_plus to read the version dynamically.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: Text(
                'About CallType v0.1.0',
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
