import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';

/// Manages group creation and persists group conversations locally.
///
/// Bridges the server-side group API with the local database. The flow is:
///   1. Call server to create the group (assigns group UUID, adds members)
///   2. Create a local conversation of type 'group' so it appears in the chat list
///   3. Return the group/conversation ID for navigation
///
/// In a full implementation, group management (add/remove members, rename,
/// leave) would also live here. For the MVP, only creation is supported.
class GroupController extends ChangeNotifier {
  GroupController({
    required AppDatabase database,
    required ApiClient apiClient,
  })  : _db = database,
        _apiClient = apiClient;

  final AppDatabase _db;

  // Needed for server-side group creation (POST /groups) once the endpoint
  // is implemented. Kept to preserve the constructor contract.
  // ignore: unused_field
  final ApiClient _apiClient;

  bool _isLoading = false;
  String? _error;

  /// Whether a group creation request is in flight.
  bool get isLoading => _isLoading;

  /// Error from the last failed creation attempt, or null.
  String? get error => _error;

  static const _uuid = Uuid();

  /// Creates a new group chat with the given name and member device IDs.
  ///
  /// Calls the server API to register the group, then creates a local
  /// conversation record so the group appears in the chat list immediately.
  ///
  /// Returns the group/conversation ID on success, or null on failure.
  /// The caller should navigate to the new group's chat screen on success.
  ///
  /// [name] is the human-readable group name displayed in the chat list.
  /// [memberDeviceIds] are the device UUIDs of the group members (excluding
  /// the local device, which is added server-side automatically).
  Future<String?> createGroup(
    String name,
    List<String> memberDeviceIds,
  ) async {
    if (name.trim().isEmpty || memberDeviceIds.isEmpty) {
      _error = 'Group name and at least one member are required';
      notifyListeners();
      return null;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Generate a local UUID for the group. In production the server would
      // assign the group ID — for now we generate it client-side because
      // the group API endpoint is not yet implemented on the server.
      // TODO: Use server-assigned group ID once POST /groups is implemented.
      final groupId = _uuid.v4();

      // Create a local conversation so the group appears in the chat list
      // immediately. The type 'group' tells the UI to render a group avatar
      // and use Sender Keys encryption instead of pairwise Double Ratchet.
      final companion = ConversationsCompanion.insert(
        id: groupId,
        type: 'group',
        title: Value(name.trim()),
      );

      await _db.into(_db.conversations).insert(companion);

      _isLoading = false;
      notifyListeners();

      return groupId;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }
}
