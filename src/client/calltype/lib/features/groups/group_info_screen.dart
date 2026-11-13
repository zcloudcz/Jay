import 'package:calltype_core/network/api_client.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/bot_badge.dart';
import 'group_info_controller.dart';
import 'group_topic_widgets.dart';

/// Group info (spec 2026-11-13-group-topics rows 12/13): the name, the full
/// topic (selectable), "Edit topic" for admins and the members with their
/// roles. Admins get a per-member menu to promote or demote other people.
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  @override
  void initState() {
    super.initState();
    final controller = context.read<GroupInfoController>();
    if (controller.loading) controller.load();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _editTopic(GroupInfoController controller) async {
    final text = await showEditTopicDialog(
      context,
      controller.topic?.topic ?? '',
    );
    if (text == null || !mounted) return;
    final l10n = context.l10n;
    final result = await controller.setTopic(text);
    if (!mounted) return;
    _snack(groupTopicResultText(l10n, result));
  }

  Future<void> _setRole(
    GroupInfoController controller,
    GroupMemberInfo member,
    bool admin,
  ) async {
    final l10n = context.l10n;
    final error = await controller.setRole(member, admin);
    if (error == null || !mounted) return;
    _snack(switch (error) {
      GroupRoleError.lastAdmin => l10n.groupRoleErrorLastAdmin,
      GroupRoleError.bot => l10n.groupRoleErrorBot,
      GroupRoleError.notAdmin => l10n.groupRoleErrorNotAdmin,
      GroupRoleError.unsupported => l10n.groupRoleErrorUnsupported,
      GroupRoleError.failed => l10n.groupRoleErrorFailed,
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<GroupInfoController>();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = controller.conversation?.title ?? controller.groupId;
    final topic = controller.topic?.topic ?? '';
    final Widget body;
    if (controller.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (controller.loadFailed) {
      body = Center(
        child: TextButton(
          onPressed: controller.load,
          child: Text(l10n.groupInfoLoadFailed, textAlign: TextAlign.center),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: LetterAvatar(name: name),
            title: Text(name, style: theme.textTheme.titleLarge),
          ),
          // No topic section in business groups (spec row 11).
          if (!controller.business) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                l10n.groupTopicLabel,
                style: theme.textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: topic.isEmpty
                  ? Text(
                      l10n.groupTopicNone,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : SelectableText(
                      topic,
                      key: const ValueKey('group-info-topic'),
                    ),
            ),
            if (controller.canEditTopic)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('group-info-edit-topic'),
                    onPressed: controller.busy
                        ? null
                        : () => _editTopic(controller),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.groupTopicEdit),
                  ),
                ),
              ),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.groupMembersHeader,
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final member in controller.members)
            _memberTile(context, controller, member),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.groupInfoTitle)),
      body: body,
    );
  }

  Widget _memberTile(
    BuildContext context,
    GroupInfoController controller,
    GroupMemberInfo member,
  ) {
    final l10n = context.l10n;
    final self = controller.isSelf(member);
    final name = self
        ? l10n.groupMemberYou
        : member.displayName ?? member.userHandle ?? member.deviceId;
    final labels = [
      if (member.role == 'admin') l10n.groupRoleAdmin,
      if (member.role == 'auditor') l10n.groupRoleAuditor,
      if (member.isBot && member.role != 'auditor') l10n.groupRoleBot,
    ];
    final makeAdmin = controller.canMakeAdmin(member);
    final removeAdmin = controller.canRemoveAdmin(member);
    final subtitle = [
      if (member.userHandle != null && member.userHandle != name)
        member.userHandle!,
      ...labels,
    ].join(' · ');
    return ListTile(
      key: ValueKey('group-member-${member.deviceId}'),
      leading: LetterAvatar(name: name),
      title: NameWithBotBadge(name: name, isBot: member.isBot),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: makeAdmin || removeAdmin
          ? PopupMenuButton<bool>(
              key: ValueKey('group-member-menu-${member.deviceId}'),
              tooltip: l10n.groupMemberActions,
              enabled: !controller.busy,
              onSelected: (admin) => _setRole(controller, member, admin),
              itemBuilder: (_) => [
                if (makeAdmin)
                  PopupMenuItem(
                    key: const ValueKey('group-make-admin'),
                    value: true,
                    child: Text(l10n.groupMakeAdmin),
                  ),
                if (removeAdmin)
                  PopupMenuItem(
                    key: const ValueKey('group-remove-admin'),
                    value: false,
                    child: Text(l10n.groupRemoveAdmin),
                  ),
              ],
            )
          : null,
    );
  }
}
