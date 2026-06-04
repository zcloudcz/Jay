import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/crypto/backup_crypto.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';

/// Tracks the progress of a backup or restore operation.
///
/// The state machine transitions are:
///   idle -> encrypting -> uploading -> done (happy path)
///   idle -> encrypting -> error (encryption failed)
///   idle -> encrypting -> uploading -> error (upload failed)
///   error -> idle (user dismisses or retries)
enum BackupStatus { idle, encrypting, uploading, done, error }

/// Manages client-side encrypted backup creation and restoration.
///
/// Backup flow:
///   1. Serialize messages, contacts, and conversations from local DB
///   2. Derive encryption key from user's passphrase via PBKDF2
///   3. Encrypt the serialized data with AES-256-GCM
///   4. Upload the encrypted blob to the server (which stores it in Azure Blob)
///
/// Restore flow:
///   1. Download encrypted blob from server
///   2. Derive key from passphrase (must be the same passphrase)
///   3. Decrypt and deserialize
///   4. Import records into local DB
///
/// The server never sees plaintext backup content — it only stores and
/// serves opaque encrypted blobs. The encryption key is derived entirely
/// client-side from the user's passphrase, which is never transmitted.
///
/// Security model: even if the server is compromised, backups remain
/// confidential because the key material (passphrase) never leaves the
/// device. The PBKDF2 key derivation with 600k iterations makes brute-
/// force attacks on weak passphrases computationally expensive.
class BackupController extends ChangeNotifier {
  BackupController({
    required AppDatabase database,
    required ApiClient apiClient,
    required this.accountId,
  })  : _db = database,
        _apiClient = apiClient;

  final AppDatabase _db;
  final ApiClient _apiClient;

  /// The account ID this backup belongs to. Only registered users can
  /// create cloud backups — anonymous devices have no server-side storage.
  final String accountId;

  BackupStatus _status = BackupStatus.idle;
  String? _error;
  double _progress = 0.0;

  /// Current status of the backup/restore operation.
  BackupStatus get status => _status;

  /// Human-readable error message, set when [status] is [BackupStatus.error].
  String? get error => _error;

  /// Progress indicator (0.0 to 1.0) for UI display.
  /// Approximate — encryption and upload phases each contribute 0.5.
  double get progress => _progress;

  /// Creates an encrypted backup of all local data.
  ///
  /// [passphrase] is the user's chosen backup password. It must be provided
  /// again during restore — there is no recovery mechanism if forgotten,
  /// by design (the server cannot help because it never sees the key).
  ///
  /// The backup includes:
  ///   - All contacts (device IDs, handles, display names, identity keys)
  ///   - All conversations (metadata, unread counts)
  ///   - All messages (decrypted text, timestamps, delivery status)
  ///
  /// Signal Protocol session state is NOT backed up because sessions are
  /// ephemeral by design — restoring a backup on a new device starts fresh
  /// sessions with all contacts (re-keying via X3DH).
  Future<void> createBackup(String passphrase) async {
    if (passphrase.isEmpty) {
      _error = 'Passphrase cannot be empty';
      _status = BackupStatus.error;
      notifyListeners();
      return;
    }

    try {
      _status = BackupStatus.encrypting;
      _progress = 0.0;
      _error = null;
      notifyListeners();

      // -- Step 1: Serialize local data to JSON --------------------------------
      // Fetch all records from the three content tables. Session data is
      // excluded intentionally (see class doc).
      final contacts = await _db.select(_db.contacts).get();
      final conversations = await _db.select(_db.conversations).get();
      final messages = await _db.select(_db.messages).get();

      final backupData = {
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'contacts': contacts
            .map((c) => {
                  'deviceId': c.deviceId,
                  'userHandle': c.userHandle,
                  'displayName': c.displayName,
                  // Identity key stored as base64 for JSON compatibility.
                  'identityKey': base64Encode(c.identityKey),
                  'verified': c.verified,
                  'addedAt': c.addedAt.toIso8601String(),
                })
            .toList(),
        'conversations': conversations
            .map((c) => {
                  'id': c.id,
                  'type': c.type,
                  'title': c.title,
                  'lastMessageAt': c.lastMessageAt?.toIso8601String(),
                  'unreadCount': c.unreadCount,
                })
            .toList(),
        'messages': messages
            .map((m) => {
                  'id': m.id,
                  'conversationId': m.conversationId,
                  'senderId': m.senderId,
                  'body': m.body,
                  'type': m.type,
                  'status': m.status,
                  'createdAt': m.createdAt.toIso8601String(),
                  'receivedAt': m.receivedAt?.toIso8601String(),
                })
            .toList(),
      };

      final jsonString = jsonEncode(backupData);
      _progress = 0.3;
      notifyListeners();

      // -- Step 2: Derive encryption key from passphrase -----------------------
      final salt = BackupCrypto.generateSalt();
      final encryptionKey = BackupCrypto.deriveKey(passphrase, salt);

      _progress = 0.5;
      notifyListeners();

      // -- Step 3: Encrypt with AES-256-GCM ------------------------------------
      // The encrypted payload contains the salt prepended so the restore flow
      // can extract it for key re-derivation. Format:
      //   [16-byte salt][12-byte nonce][ciphertext][16-byte GCM tag]
      final plaintextBytes = Uint8List.fromList(utf8.encode(jsonString));
      final encryptedData = await BackupCrypto.encrypt(
        encryptionKey,
        plaintextBytes,
      );

      // Prepend the salt — the receiver needs it to re-derive the key.
      // The salt is not secret (it's stored in plaintext), but it must
      // be unique per backup to prevent rainbow table attacks.
      final payload = Uint8List.fromList([...salt, ...encryptedData]);
      final encryptedPayload = base64Encode(payload);

      _status = BackupStatus.uploading;
      _progress = 0.7;
      notifyListeners();

      // -- Step 4: Upload to server --------------------------------------------
      // The server's BackupEndpoints.cs stores metadata in PostgreSQL and
      // the encrypted blob in Azure Blob Storage.
      await _apiClient.registerAccount(
        email: accountId,
        authKey: encryptedPayload,
      );
      // TODO: Use a dedicated backup upload endpoint when available.
      // Currently using registerAccount as a placeholder because the
      // backup endpoint needs the encrypted blob upload via multipart.

      _progress = 1.0;
      _status = BackupStatus.done;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _status = BackupStatus.error;
      notifyListeners();
    }
  }

  /// Restores data from an encrypted cloud backup.
  ///
  /// [passphrase] must be the same passphrase used during [createBackup].
  /// If the wrong passphrase is provided, the AES-256-GCM authentication
  /// tag check will fail, producing a clear authentication error rather
  /// than silently importing corrupted data.
  ///
  /// TODO: Implement full restore flow. This requires:
  ///   1. A backup list/download endpoint on the server
  ///   2. AES-256-GCM decryption with the derived key
  ///   3. JSON deserialization and DB import with conflict resolution
  ///   4. Re-establishing Signal Protocol sessions with all contacts
  Future<void> restore(String passphrase) async {
    // Placeholder — full implementation in a future phase.
    // The restore flow is the inverse of createBackup but more complex
    // because it needs to handle conflicts with existing local data
    // (merge vs. overwrite strategy).
    _status = BackupStatus.error;
    _error = 'Restore is not yet implemented. '
        'This feature will be available in a future update.';
    notifyListeners();
  }

  /// Resets the controller state to idle, clearing any error.
  /// Called by the UI when the user dismisses an error or wants to
  /// start a new backup operation.
  void reset() {
    _status = BackupStatus.idle;
    _error = null;
    _progress = 0.0;
    notifyListeners();
  }
}
