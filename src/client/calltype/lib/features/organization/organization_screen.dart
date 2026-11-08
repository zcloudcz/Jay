import 'dart:typed_data';

import 'package:calltype_core/network/organization_dtos.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import 'business_banner.dart';
import 'mfa_flow.dart';
import 'mfa_section.dart';
import 'organization_controller.dart';

/// Organization settings screen (E05 deliverable 1).
///
/// Shows one of two states:
///   - No organization: an invite-code join form (+ "create organization"
///     for accounts that want to start one).
///   - Member of an organization: membership card, and — for owner/orgAdmin
///     — the admin tools (members, invites, revoke, export audit, set the
///     auditor device id).
class OrganizationScreen extends StatefulWidget {
  const OrganizationScreen({super.key});

  @override
  State<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends State<OrganizationScreen> {
  final _codeController = TextEditingController();
  final _orgNameController = TextEditingController();
  final _auditorController = TextEditingController();
  String? _accountId;

  @override
  void initState() {
    super.initState();
    // Deferred to after the first frame: the MFA prompt dialog needs a
    // BuildContext, and the controller must have it wired before load()
    // can hit `mfa_required` on the audit-count call.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final controller = context.read<OrganizationController>();
      _accountId = await context.read<SecureStorage>().getAccountId();
      if (!mounted) return;
      controller.promptForMfa = () => _accountId == null
          ? Future.value(false)
          : runMfaStepUpFlow(context, context.read<ApiClient>(), _accountId!);
      await controller.load();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    _orgNameController.dispose();
    _auditorController.dispose();
    super.dispose();
  }

  String _errorText(BuildContext context, String code) =>
      context.l10n.orgErrorGeneric(code);

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OrganizationController>();
    final l10n = context.l10n;
    final org = controller.organization;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.orgSettingsTitle)),
      body: controller.locked
          ? MfaLockedPlaceholder(onUnlock: () => controller.load())
          : controller.isLoading && org == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (controller.errorCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _errorText(context, controller.errorCode!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (org == null) ..._joinAndCreate(context, controller),
                if (org != null) ..._membership(context, controller, org),
                if (org != null && org.isAdmin && _accountId != null) ...[
                  const Divider(height: 32),
                  MfaSection(accountId: _accountId!),
                ],
              ],
            ),
    );
  }

  List<Widget> _joinAndCreate(
    BuildContext context,
    OrganizationController controller,
  ) {
    final l10n = context.l10n;
    return [
      Text(l10n.orgJoinTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      TextField(
        controller: _codeController,
        decoration: InputDecoration(labelText: l10n.orgJoinCodeLabel),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: controller.isLoading
            ? null
            : () async {
                await controller.enroll(_codeController.text.trim());
                if (controller.errorCode != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.orgJoinFailed)),
                  );
                }
              },
        child: Text(l10n.orgJoinButton),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.emergency_outlined),
        label: Text(l10n.emergencyHaveCode),
        onPressed: () => context.push('/settings/organization/emergency-enroll'),
      ),
      const Divider(height: 32),
      Text(l10n.orgCreateRequiresAccount),
      const SizedBox(height: 8),
      TextField(
        controller: _orgNameController,
        decoration: InputDecoration(labelText: l10n.orgSettingsTitle),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: controller.isLoading
            ? null
            : () => controller.createOrganization(_orgNameController.text.trim()),
        child: Text(l10n.orgCreateButton),
      ),
    ];
  }

  List<Widget> _membership(
    BuildContext context,
    OrganizationController controller,
    OrganizationInfo org,
  ) {
    final l10n = context.l10n;
    final isAdmin = org.isAdmin;
    return [
      Card(
        child: ListTile(
          title: Text(org.name),
          subtitle: Text(l10n.orgMembershipCard(org.name, org.role)),
          trailing: TextButton(
            onPressed: () => showBusinessInfoSheet(context, org.name),
            child: Text(l10n.businessInfoTitle),
          ),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        icon: const Icon(Icons.group_add_outlined),
        label: Text(l10n.orgMembersTitle),
        onPressed: () => context.push(
          '/groups/create?orgId=${org.organizationId}&orgName=${Uri.encodeComponent(org.name)}',
        ),
      ),
      if (isAdmin) ...[
        const Divider(height: 32),
        OutlinedButton.icon(
          icon: const Icon(Icons.emergency_outlined),
          label: Text(l10n.emergencyTitle),
          onPressed: () => context.push(
            '/settings/organization/emergency?orgId=${org.organizationId}',
          ),
        ),
        const Divider(height: 32),
        SwitchListTile(
          title: Text(l10n.orgRequireBusinessConversationsTitle),
          subtitle: Text(l10n.orgRequireBusinessConversationsExplanation),
          value: org.requireBusinessConversations,
          onChanged: (value) =>
              controller.setRequireBusinessConversations(value),
        ),
        const Divider(height: 32),
        Text(l10n.orgMembersTitle, style: Theme.of(context).textTheme.titleMedium),
        for (final member in controller.members)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(member.accountId),
            subtitle: Text(member.role),
          ),
        const SizedBox(height: 8),
        Text(
          controller.auditRecordCount != null && controller.auditRecordCount! > 0
              ? l10n.orgArchiveActive
              : l10n.orgArchiveInactive,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.qr_code),
          label: Text(l10n.orgInviteCreate),
          onPressed: () async {
            final invite = await controller.createInvite();
            if (invite != null && context.mounted) {
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  content: Text(l10n.orgInviteCodeLabel(invite.code)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(MaterialLocalizations.of(context).okButtonLabel),
                    ),
                  ],
                ),
              );
            }
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _auditorController,
          decoration: InputDecoration(
            labelText: l10n.orgSetAuditorLabel,
            hintText: org.auditorDeviceId,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => controller.setAuditorDevice(_auditorController.text.trim()),
          child: Text(l10n.orgSetAuditorLabel),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: Text(l10n.orgExportAudit),
          onPressed: () async {
            final bytes = await controller.exportAdminAudit();
            if (bytes != null) {
              await FilePicker.saveFile(
                fileName: 'admin-audit-${org.organizationId}.csv',
                bytes: Uint8List.fromList(bytes),
              );
            }
          },
        ),
      ],
    ];
  }
}
