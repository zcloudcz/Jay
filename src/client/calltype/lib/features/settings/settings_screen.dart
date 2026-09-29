import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/network/webrtc_manager.dart';
import '../../l10n/l10n.dart';
import '../../shared/widgets/app_version_label.dart';

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
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          // -- Security section ------------------------------------------------
          _SettingsTile(
            icon: Icons.lock_rounded,
            iconColor: colorScheme.primary,
            title: l10n.settingsAppLock,
            subtitle: l10n.settingsAppLockSubtitle,
            onTap: () => context.push('/settings/lock'),
          ),

          // -- Account section ------------------------------------------------
          _SettingsTile(
            icon: Icons.person_rounded,
            iconColor: colorScheme.primary,
            title: l10n.settingsAccount,
            subtitle: l10n.settingsAccountSubtitle,
            onTap: () => context.push('/settings/account'),
          ),

          // -- Data section ---------------------------------------------------
          _SettingsTile(
            icon: Icons.cloud_upload_rounded,
            iconColor: colorScheme.primary,
            title: l10n.settingsBackup,
            subtitle: l10n.settingsBackupSubtitle,
            onTap: () => context.push('/settings/backup'),
          ),

          // -- Devices section ------------------------------------------------
          _SettingsTile(
            icon: Icons.devices_rounded,
            iconColor: colorScheme.primary,
            title: l10n.settingsIdentity,
            subtitle: l10n.settingsIdentitySubtitle,
            onTap: () => context.push('/settings/identity'),
          ),

          // -- Channels section -----------------------------------------------
          // Blocking a channel is local to this device, so the only place
          // to undo it has to be reachable without the (blocked) channel.
          _SettingsTile(
            icon: Icons.block_rounded,
            iconColor: colorScheme.primary,
            title: l10n.settingsBlockedChannels,
            subtitle: l10n.settingsBlockedChannelsSubtitle,
            onTap: () => context.push('/channels/blocked'),
          ),

          // -- Business mode (Jay) ---------------------------------------------
          _SettingsTile(
            icon: Icons.verified_user_rounded,
            iconColor: colorScheme.primary,
            title: l10n.orgSettingsTitle,
            subtitle: l10n.orgJoinTitle,
            onTap: () => context.push('/settings/organization'),
          ),

          const Divider(indent: 16, endIndent: 16),

          // -- Diagnostics section --------------------------------------------
          // Beta acceptance needs proof that calls really work through the
          // TURN relay (not just direct P2P). This forces relay-only ICE for
          // the next calls; it is in-memory and resets on app restart.
          SwitchListTile(
            secondary: Icon(Icons.alt_route_rounded, color: colorScheme.tertiary),
            title: Text(l10n.settingsForceRelay),
            subtitle: Text(l10n.settingsForceRelaySubtitle),
            value: context.watch<WebRTCManager>().forceIceRelay,
            onChanged: context.read<WebRTCManager>().setForceIceRelay,
          ),

          const Divider(indent: 16, endIndent: 16),

          // -- About section --------------------------------------------------
          // Real build name + number from the bundle (P2), same as the
          // release manifest.
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(child: AppVersionLabel()),
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
