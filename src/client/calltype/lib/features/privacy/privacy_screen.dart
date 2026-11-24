import 'package:calltype_core/network/api_client.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import 'block_controller.dart';
import 'data_export.dart';
import 'legal_links.dart';
import 'user_safety_actions.dart';

/// Settings > Privacy (spec 2026-11-14-go-live A4): export my data, the
/// blocked people and the legal pages.
class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  bool _exporting = false;

  Future<void> _export() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiClient>();
    final storage = context.read<SecureStorage>();
    setState(() => _exporting = true);
    try {
      final deviceId = await storage.getDeviceId();
      if (deviceId == null) throw StateError('not registered');
      final saved = await exportMyData(
        api: api,
        deviceId: deviceId,
        accountId: await storage.getAccountId(),
      );
      if (saved) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.privacyExportDone)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.privacyExportFailed)));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final blockedCount = context.watch<BlockController>().blocked.length;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsPrivacy)),
      body: ListView(
        children: [
          ListTile(
            key: const ValueKey('privacy-export'),
            leading: Icon(
              Icons.download_rounded,
              color: theme.colorScheme.primary,
            ),
            title: Text(l10n.privacyExportTitle),
            subtitle: Text(l10n.privacyExportBody),
            isThreeLine: true,
            trailing: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _exporting ? null : _export,
          ),
          ListTile(
            key: const ValueKey('privacy-blocked'),
            leading: Icon(
              Icons.block_rounded,
              color: theme.colorScheme.primary,
            ),
            title: Text(l10n.privacyBlockedUsers),
            subtitle: Text(l10n.privacyBlockedUsersSubtitle),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (blockedCount > 0) Text('$blockedCount'),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
            onTap: () => context.push('/settings/privacy/blocked'),
          ),
          const Divider(indent: 16, endIndent: 16),
          const LegalPageTile(page: LegalPage.privacy),
          const LegalPageTile(page: LegalPage.terms),
        ],
      ),
    );
  }
}

/// Settings > Privacy > Blocked people: the only place to undo a block of a
/// person whose chat is hidden.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  @override
  void initState() {
    super.initState();
    // The server list is the truth (a block set on another own device).
    context.read<BlockController>().refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final blocked = context.watch<BlockController>().blocked;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyBlockedUsers)),
      body: blocked.isEmpty
          ? Center(child: Text(l10n.blockedUsersEmpty))
          : ListView.builder(
              itemCount: blocked.length,
              itemBuilder: (context, index) {
                final user = blocked[index];
                final name =
                    user.displayName ??
                    (user.userHandle.isNotEmpty
                        ? user.userHandle
                        : user.deviceId);
                return ListTile(
                  key: ValueKey('blocked-${user.deviceId}'),
                  leading: const Icon(Icons.person_off_outlined),
                  title: Text(name),
                  subtitle:
                      user.userHandle.isNotEmpty && user.userHandle != name
                      ? Text(user.userHandle)
                      : null,
                  trailing: TextButton(
                    key: ValueKey('unblock-${user.deviceId}'),
                    onPressed: () =>
                        unblockUser(context, id: user.deviceId, name: name),
                    child: Text(l10n.userUnblock),
                  ),
                );
              },
            ),
    );
  }
}
