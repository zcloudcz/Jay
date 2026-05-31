import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/storage/database.dart';

/// Manages the local contact list — devices we have exchanged identity
/// keys with or intend to communicate with.
///
/// Contacts are stored locally and never synced to the server, preserving
/// the anonymous-first design. A contact is created when:
///   1. The user scans a QR code (gets handle + deviceId)
///   2. The user manually enters a handle
///   3. A message arrives from an unknown sender (auto-create)
///
/// The identity key exchange happens lazily on first message send —
/// the sender fetches the recipient's key bundle from the server and
/// performs X3DH. This means a contact can exist in the DB before any
/// cryptographic session is established.
class ContactsController extends ChangeNotifier {
  ContactsController({required AppDatabase database}) : _db = database;

  final AppDatabase _db;

  /// All known contacts, ordered by display name / handle.
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<Contact> _contacts = [];

  /// Loads all contacts from the local database.
  ///
  /// Orders by displayName (if set), falling back to userHandle for
  /// contacts that haven't been given a custom name yet.
  Future<void> loadContacts() async {
    final query = _db.select(_db.contacts)
      ..orderBy([
        // COALESCE equivalent — sort by displayName if present, else handle.
        (c) => OrderingTerm(expression: c.displayName),
        (c) => OrderingTerm(expression: c.userHandle),
      ]);

    _contacts = await query.get();
    notifyListeners();
  }

  /// Adds a contact by their human-readable handle (e.g. ZM-A1B2-C3D4).
  ///
  /// The handle is stored immediately. The actual key exchange happens
  /// on first message send — at that point the app fetches the key bundle
  /// from the server via the deviceId and performs X3DH.
  ///
  /// A placeholder identity key (empty bytes) is stored because the
  /// Contacts table requires a non-null identityKey. It will be populated
  /// when the key bundle is fetched during session initialization.
  ///
  /// [handle] must match the ZM-XXXX-XXXX format.
  /// [deviceId] is optional — if provided (e.g. from QR scan), it's used
  /// as the primary key. If not, the handle itself is used as a temporary
  /// deviceId until the server resolves it.
  Future<void> addContactByHandle(
    String handle, {
    String? deviceId,
  }) async {
    final id = deviceId ?? handle;

    // Check if this contact already exists to avoid duplicates.
    final existing = await (_db.select(_db.contacts)
          ..where((c) => c.deviceId.equals(id)))
        .getSingleOrNull();

    if (existing != null) return;

    final companion = ContactsCompanion.insert(
      deviceId: id,
      userHandle: handle,
      // Placeholder — real identity key is populated during X3DH handshake
      // when the first message is sent to this contact.
      identityKey: Uint8List(0),
      addedAt: DateTime.now(),
    );

    await _db.into(_db.contacts).insert(companion);
    await loadContacts();
  }
}
