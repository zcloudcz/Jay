import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../../shared/widgets/avatar.dart';
import 'group_controller.dart';

/// Screen for creating a new group chat.
///
/// Layout:
///   - Group name text field at the top
///   - Scrollable contact list with checkboxes for member selection
///   - "Create" button in the AppBar (disabled until name + members are set)
///
/// Loads contacts from the database on init. The GroupController handles
/// the actual group creation (API call + local DB insert).
class GroupCreateScreen extends StatefulWidget {
  const GroupCreateScreen({
    super.key,
    this.organizationId,
    this.organizationName,
  });

  /// Set when creating a business group from Organization settings (E05).
  /// The server is the actual enforcement point for "only enrolled members
  /// allowed" — this screen only carries the id through to `createGroup`.
  final String? organizationId;
  final String? organizationName;

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _nameController = TextEditingController();
  late final GroupController _controller;
  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Device IDs of selected group members.
  final Set<String> _selectedMembers = {};

  /// Contact list loaded from local database.
  List<dynamic> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = GroupController(
      database: context.read<AppDatabase>(),
      apiClient: context.read<ApiClient>(),
    )..addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadContacts());
    _nameController.addListener(_refresh);
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// Loads contacts from the database to populate the member selection list.
  Future<void> _loadContacts() async {
    if (!mounted) return;
    final db = context.read<AppDatabase>();
    final contacts = await db.select(db.contacts).get();
    if (mounted) {
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    }
  }

  /// Whether the create button should be enabled.
  /// Requires both a non-empty name and at least one selected member.
  bool get _canCreate =>
      _nameController.text.trim().isNotEmpty &&
      _selectedMembers.isNotEmpty &&
      !_controller.isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.groupNewTitle),
        actions: [
          // Create button — only enabled when validation passes.
          TextButton(
            onPressed: _canCreate ? _createGroup : null,
            child: _controller.isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.groupCreate),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // -- Group name input -----------------------------------------
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _nameController,
                    enabled: !_controller.isLoading,
                    decoration: InputDecoration(
                      labelText: l10n.groupNameLabel,
                      hintText: l10n.groupNameHint,
                      prefixIcon: const Icon(Icons.group_rounded),
                      border: const OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),

                // -- Member selection header ----------------------------------
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Text(
                        l10n.groupSelectMembers,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Show selection count as a badge so the user knows
                      // how many members are chosen without scrolling.
                      if (_selectedMembers.isNotEmpty)
                        Chip(
                          label: Text(
                            l10n.groupSelectedCount(_selectedMembers.length),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),

                // -- Contact list with checkboxes -----------------------------
                Expanded(
                  child: _contacts.isEmpty
                      ? Center(
                          child: Text(
                            l10n.groupNoContacts,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _contacts.length,
                          itemBuilder: (context, index) {
                            final contact = _contacts[index];
                            final deviceId = contact.deviceId as String;
                            final name =
                                (contact.displayName as String?) ??
                                contact.userHandle as String;
                            final isSelected = _selectedMembers.contains(
                              deviceId,
                            );

                            return CheckboxListTile(
                              value: isSelected,
                              onChanged: _controller.isLoading
                                  ? null
                                  : (checked) {
                                      setState(() {
                                        if (checked == true) {
                                          _selectedMembers.add(deviceId);
                                        } else {
                                          _selectedMembers.remove(deviceId);
                                        }
                                      });
                                    },
                              secondary: LetterAvatar(name: name),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                contact.userHandle as String,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  /// Creates the group via the controller and navigates to the new chat.
  Future<void> _createGroup() async {
    if (!_canCreate) return;
    final groupId = await _controller.createGroup(
      _nameController.text,
      _selectedMembers.toList(),
      organizationId: widget.organizationId,
      organizationName: widget.organizationName,
    );

    if (groupId != null && mounted) {
      // Navigate to the new group chat, replacing the create screen
      // so the user can't go "back" to the creation form.
      context.go('/chats/$groupId');
    } else if (_controller.error != null && mounted) {
      // The controller's error is raw exception text meant for developers;
      // the user gets a localized, actionable line instead.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.groupCreateFailed)));
    }
  }
}
