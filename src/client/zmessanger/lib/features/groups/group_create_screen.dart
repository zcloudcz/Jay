import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
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
  const GroupCreateScreen({super.key});

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _nameController = TextEditingController();

  /// Device IDs of selected group members.
  final Set<String> _selectedMembers = {};

  /// Contact list loaded from local database.
  List<dynamic> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadContacts());
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Loads contacts from the database to populate the member selection list.
  Future<void> _loadContacts() async {
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
      _nameController.text.trim().isNotEmpty && _selectedMembers.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Group'),
        actions: [
          // Create button — only enabled when validation passes.
          TextButton(
            onPressed: _canCreate ? _createGroup : null,
            child: const Text('Create'),
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
                    decoration: const InputDecoration(
                      labelText: 'Group name',
                      hintText: 'e.g. Project Team',
                      prefixIcon: Icon(Icons.group_rounded),
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),

                // -- Member selection header ----------------------------------
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        'Select members',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Show selection count as a badge so the user knows
                      // how many members are chosen without scrolling.
                      if (_selectedMembers.isNotEmpty)
                        Chip(
                          label: Text('${_selectedMembers.length}'),
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
                            'No contacts yet.\nAdd contacts first to create a group.',
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
                            final isSelected =
                                _selectedMembers.contains(deviceId);

                            return CheckboxListTile(
                              value: isSelected,
                              onChanged: (checked) {
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
    final db = context.read<AppDatabase>();
    final apiClient = context.read<ApiClient>();

    final controller = GroupController(
      database: db,
      apiClient: apiClient,
    );

    final groupId = await controller.createGroup(
      _nameController.text,
      _selectedMembers.toList(),
    );

    if (groupId != null && mounted) {
      // Navigate to the new group chat, replacing the create screen
      // so the user can't go "back" to the creation form.
      context.go('/chats/$groupId');
    } else if (controller.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error!)),
      );
    }
  }
}
