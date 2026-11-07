import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/crypto/backup_crypto.dart';
import '../../core/network/api_client.dart';
import '../../core/network/backup_api.dart';
import 'backup_import.dart';
import '../../core/storage/database.dart';
import '../../l10n/l10n.dart';

/// Server-side backup quota, mirrored here purely for display copy (K03
/// defaults in appsettings.json). Not fetched from the server — there is no
/// limits endpoint. ponytail: if these ever diverge from the server config,
/// add a GET that returns them instead of hardcoding a second copy.
const int kBackupMaxFileBytes = 8 * 1024 * 1024;
const int kBackupMaxPerAccount = 3;

/// Tracks the progress of a backup or restore operation.
///
/// The state machine transitions are:
///   idle -> encrypting -> uploading -> done (happy path)
///   idle -> encrypting -> error (encryption failed)
///   idle -> encrypting -> uploading -> error (upload failed)
///   error -> idle (user dismisses or retries)
enum BackupStatus {
  idle,
  encrypting,
  uploading,
  downloading,
  restoring,
  done,
  error,
}

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
/// Why a backup / restore failed. The controller has no BuildContext, so it
/// reports a code and [backupErrorMessage] turns it into localized text.
enum BackupError {
  emptyPassphrase,
  sessionExpired,
  forbidden,
  limitReached,
  fileTooLarge,
  network,
  requestFailed,
  noBackups,
  invalidFile,
  restoreFailed,
  unknown,
}

/// Carries a [BackupError] out of the restore flow's single try/catch.
class _BackupFailure implements Exception {
  const _BackupFailure(this.code);
  final BackupError code;
}

/// Localized text for [BackupController.error]; null while there is no error.
String? backupErrorMessage(AppLocalizations l10n, BackupController c) =>
    switch (c.error) {
      null => null,
      BackupError.emptyPassphrase => l10n.backupErrorEmptyPassphrase,
      BackupError.sessionExpired => l10n.backupErrorSessionExpired,
      BackupError.forbidden => l10n.backupErrorForbidden,
      BackupError.limitReached => l10n.backupErrorLimitReached(
        kBackupMaxPerAccount,
      ),
      BackupError.fileTooLarge => l10n.backupErrorTooLarge(
        kBackupMaxFileBytes ~/ (1024 * 1024),
      ),
      BackupError.network => l10n.backupErrorNetwork,
      BackupError.requestFailed => l10n.backupErrorRequestFailed(
        c.errorStatusCode ?? 0,
      ),
      BackupError.noBackups => l10n.backupErrorNoBackups,
      BackupError.invalidFile => l10n.backupErrorInvalidFile,
      BackupError.restoreFailed => l10n.backupErrorRestoreFailed,
      BackupError.unknown => l10n.backupErrorUnknown,
    };

class BackupController extends ChangeNotifier {
  BackupController({
    required AppDatabase database,
    required ApiClient apiClient,
    required this.accountId,
  }) : _db = database,
       _apiClient = apiClient;

  final AppDatabase _db;
  final ApiClient _apiClient;

  /// The account ID this backup belongs to. Only registered users can
  /// create cloud backups — anonymous devices have no server-side storage.
  final String accountId;

  BackupStatus _status = BackupStatus.idle;
  BackupError? _error;
  bool _disposed = false;

  /// HTTP status behind [BackupError.requestFailed], shown to the user.
  int? errorStatusCode;

  /// Which operation finished last — the screens pick the success text.
  bool lastOperationWasRestore = false;
  double _progress = 0.0;

  /// Cached list of completed backups for this account, as returned by
  /// GET /backups/{accountId}. Populated by [loadBackups]; the UI calls it
  /// on screen entry and again after a successful delete.
  List<Map<String, dynamic>> backups = [];

  /// Current status of the backup/restore operation.
  BackupStatus get status => _status;

  /// Error code, set when [status] is [BackupStatus.error]; see
  /// [backupErrorMessage] for the user-facing text.
  BackupError? get error => _error;

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
    if (isBusy) return;
    if (passphrase.isEmpty) {
      _error = BackupError.emptyPassphrase;
      _status = BackupStatus.error;
      if (!_disposed) notifyListeners();
      return;
    }

    try {
      _status = BackupStatus.encrypting;
      _progress = 0.0;
      _error = null;
      if (!_disposed) notifyListeners();

      // -- Step 1: Serialize local data to JSON --------------------------------
      // Fetch all records from the three content tables. Session data is
      // excluded intentionally (see class doc).
      final snapshot = await _db.transaction(
        () async => (
          await _db.select(_db.contacts).get(),
          await _db.select(_db.conversations).get(),
          await _db.select(_db.messages).get(),
          await _db.select(_db.messageReactions).get(),
        ),
      );
      final contacts = snapshot.$1;
      final conversations = snapshot.$2;
      final messages = snapshot.$3;
      final reactions = snapshot.$4;

      final backupData = {
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'contacts': contacts
            .map(
              (c) => {
                'deviceId': c.deviceId,
                'userHandle': c.userHandle,
                'displayName': c.displayName,
                // Identity key stored as base64 for JSON compatibility.
                'identityKey': base64Encode(c.identityKey),
                'verified': c.verified,
                'addedAt': c.addedAt.toIso8601String(),
              },
            )
            .toList(),
        'conversations': conversations
            .map(
              (c) => {
                'id': c.id,
                'type': c.type,
                'title': c.title,
                'lastMessageAt': c.lastMessageAt?.toIso8601String(),
                'unreadCount': c.unreadCount,
              },
            )
            .toList(),
        'messages': messages
            .map(
              (m) => {
                'id': m.id,
                'conversationId': m.conversationId,
                'senderId': m.senderId,
                'body': m.body,
                'type': m.type,
                'status': m.status,
                'createdAt': m.createdAt.toIso8601String(),
                'receivedAt': m.receivedAt?.toIso8601String(),
                'replyToId': m.replyToId,
                'replySenderId': m.replySenderId,
                'replyPreview': m.replyPreview,
                'forwarded': m.forwarded,
                'deleted': m.deleted,
                // Agent messaging (contract section 3): carried like the
                // reply fields so a restored bot message keeps its buttons
                // and an edited one its label.
                'editedAt': m.editedAt?.toIso8601String(),
                'actionsJson': m.actionsJson,
              },
            )
            .toList(),
        // Additive (spec 2026-11-07-message-reactions): older backups have
        // no such key and restore without reactions.
        'reactions': reactions
            .map(
              (r) => {
                'messageId': r.messageId,
                'reactorId': r.reactorId,
                'conversationId': r.conversationId,
                'emoji': r.emoji,
                'reactedAt': r.reactedAt,
              },
            )
            .toList(),
      };

      final jsonString = jsonEncode(backupData);
      _progress = 0.3;
      if (!_disposed) notifyListeners();

      // -- Step 2: Derive encryption key from passphrase -----------------------
      final salt = BackupCrypto.generateSalt();
      final encryptionKey = await compute(_deriveBackupKey, (passphrase, salt));

      _progress = 0.5;
      if (!_disposed) notifyListeners();

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

      _status = BackupStatus.uploading;
      _progress = 0.7;
      if (!_disposed) notifyListeners();

      // -- Step 4: Upload to server --------------------------------------------
      // The server's BackupEndpoints.cs stores metadata in PostgreSQL and
      // the encrypted blob in Azure Blob Storage.
      await _apiClient.uploadBackup(accountId, payload);
      lastOperationWasRestore = false;

      _progress = 1.0;
      _status = BackupStatus.done;
      if (!_disposed) notifyListeners();
    } catch (e) {
      // Any failure here (encryption, network, quota) leaves local data
      // untouched — this method never writes to _db, only reads from it.
      _error = _describeError(e);
      _status = BackupStatus.error;
      if (!_disposed) notifyListeners();
    }
  }

  /// Refreshes [backups] from the server. Best-effort — a failure here
  /// (e.g. offline) leaves the previous list displayed rather than clearing it.
  Future<void> loadBackups() async {
    try {
      backups = await _apiClient.listBackups(accountId);
    } catch (_) {
      // Keep whatever was loaded before; the settings screen already shows
      // a way to retry (pull-to-refresh / re-entering the screen).
    }
    if (!_disposed) notifyListeners();
  }

  /// Deletes a backup. The endpoint is idempotent (204 even if already
  /// gone), so this is safe to retry. Refreshes [backups] on success.
  Future<void> deleteBackup(int backupId) async {
    try {
      await _apiClient.deleteBackup(accountId, backupId);
      await loadBackups();
    } catch (e) {
      _error = _describeError(e);
      _status = BackupStatus.error;
      if (!_disposed) notifyListeners();
    }
  }

  /// Classifies transport errors so the UI can show copy a non-technical
  /// user can act on.
  /// Local history is never touched by any of these failures — callers only
  /// reach this after a read-only network call.
  BackupError _describeError(Object e) {
    if (e is DioException) {
      switch (e.response?.statusCode) {
        case 401:
          return BackupError.sessionExpired;
        case 403:
          return BackupError.forbidden;
        case 409:
          return BackupError.limitReached;
        case 413:
          return BackupError.fileTooLarge;
        case null:
          return BackupError.network;
        default:
          errorStatusCode = e.response!.statusCode;
          return BackupError.requestFailed;
      }
    }
    return BackupError.unknown;
  }

  bool get isBusy =>
      _status == BackupStatus.encrypting ||
      _status == BackupStatus.uploading ||
      _status == BackupStatus.downloading ||
      _status == BackupStatus.restoring;

  Future<void> restore(String passphrase) async {
    if (isBusy) return;
    try {
      if (passphrase.isEmpty) {
        throw const _BackupFailure(BackupError.emptyPassphrase);
      }
      _status = BackupStatus.downloading;
      _error = null;
      _progress = 0;
      if (!_disposed) notifyListeners();
      final backups = await _apiClient.listBackups(accountId);
      if (backups.isEmpty) {
        throw const _BackupFailure(BackupError.noBackups);
      }
      final payload = await _apiClient.downloadBackup(
        accountId,
        backups.first['id'] as int,
      );
      if (payload.length < 44) {
        throw const _BackupFailure(BackupError.invalidFile);
      }
      _status = BackupStatus.restoring;
      _progress = 0.5;
      if (!_disposed) notifyListeners();
      final key = await compute(_deriveBackupKey, (
        passphrase,
        Uint8List.sublistView(payload, 0, 16),
      ));
      final plaintext = await BackupCrypto.decrypt(
        key,
        Uint8List.sublistView(payload, 16),
      );
      await importBackup(_db, jsonDecode(utf8.decode(plaintext)));
      lastOperationWasRestore = true;
      _progress = 1;
      _status = BackupStatus.done;
    } catch (e) {
      // importBackup validates the whole payload before writing anything, and
      // wraps its DB writes in a single transaction — a bad passphrase,
      // corrupted blob, or failure partway through never leaves target's
      // local DB partially modified.
      // Anything that is not a transport problem means the payload could not
      // be decrypted or parsed — i.e. wrong passphrase or damaged file.
      _error = e is _BackupFailure
          ? e.code
          : e is DioException
          ? _describeError(e)
          : BackupError.restoreFailed;
      _status = BackupStatus.error;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Resets the controller state to idle, clearing any error.
  /// Called by the UI when the user dismisses an error or wants to
  /// start a new backup operation.
  void reset() {
    _status = BackupStatus.idle;
    _error = null;
    _progress = 0.0;
    if (!_disposed) notifyListeners();
  }
}

Uint8List _deriveBackupKey((String, Uint8List) input) =>
    BackupCrypto.deriveKey(input.$1, input.$2);
