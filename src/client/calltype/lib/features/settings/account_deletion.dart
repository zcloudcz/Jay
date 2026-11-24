import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/user_safety_api.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/app_lock.dart';
import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../chat/message_inbox_service.dart' show MessageProcessingQueue;
import '../devices/device_service.dart';
import '../privacy/legal_links.dart';

/// Why the server refused an account deletion. Every one of them means
/// that NOTHING local was deleted, so the user can fix it and retry.
enum AccountDeletionError { wrongPassphrase, ownsOrganization, auditor, failed }

class AccountDeletionException implements Exception {
  const AccountDeletionException(this.error);
  final AccountDeletionError error;
}

/// Empties every drift table in one transaction, inside the message queue so
/// no inbox job writes between the deletes (spec 2026-11-14-go-live D12).
Future<void> wipeDatabase(AppDatabase db) =>
    MessageProcessingQueue.forDatabase(db).run(
      () => db.transaction(() async {
        for (final table in db.allTables) {
          await db.delete(table).go();
        }
      }),
    );

/// "Delete account" (spec 2026-11-14-go-live A1-A3, D10-D12): the server
/// first, then the local wipe. The local data is only wiped after the server
/// confirmed, so a refused or failed call leaves the app fully usable.
class AccountDeletionService {
  AccountDeletionService({
    required ApiClient api,
    required SecureStorage storage,
    required bool Function() isCompanion,
    required Future<void> Function() wipeLocal,
  }) : _api = api,
       _storage = storage,
       _isCompanion = isCompanion,
       _wipeLocal = wipeLocal;

  final ApiClient _api;
  final SecureStorage _storage;
  final bool Function() _isCompanion;
  final Future<void> Function() _wipeLocal;

  /// Throws [AccountDeletionException]. [passphrase] is required when the
  /// device is linked to an account (the server wants the auth key as proof).
  Future<void> deleteEverything({String? passphrase}) async {
    final deviceId = await _storage.getDeviceId();
    if (deviceId == null) {
      throw const AccountDeletionException(AccountDeletionError.failed);
    }
    final accountId = await _storage.getAccountId();
    if (accountId != null) {
      if (passphrase == null || passphrase.isEmpty) {
        throw const AccountDeletionException(
          AccountDeletionError.wrongPassphrase,
        );
      }
      // Same derivation as registration and login (account_screen.dart).
      final authKey = sha256.convert(utf8.encode(passphrase)).toString();
      try {
        await _api.deleteAccount(accountId, authKey);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        // 404: already gone (an earlier attempt that lost its answer).
        if (status != 404) {
          throw AccountDeletionException(switch (status) {
            403 => AccountDeletionError.wrongPassphrase,
            409 => AccountDeletionError.ownsOrganization,
            _ => AccountDeletionError.failed,
          });
        }
      }
      // The account is gone: a retry after a failed device step must not
      // ask the server about it again (it would answer 403).
      await _storage.delete('ct_account_id');
    }
    try {
      // D10: a primary deletes the whole identity, its companions included;
      // a companion can only delete itself.
      await _api.deleteDevice(deviceId, includeCompanions: !_isCompanion());
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) {
        throw AccountDeletionException(
          apiErrorCode(e) == 'device_is_auditor'
              ? AccountDeletionError.auditor
              : AccountDeletionError.failed,
        );
      }
    }
    await _wipeLocal();
  }
}

/// Re-authentication before the irreversible step (spec D11): true when the
/// app lock is off, or the user passed biometrics or the app PIN.
typedef DeletionReauth = Future<bool> Function(BuildContext context);

Future<bool> appLockReauth(BuildContext context) async {
  final AppLock lock;
  try {
    lock = context.read<AppLock>();
  } on ProviderNotFoundException {
    return true;
  }
  if (!await lock.isEnabled()) return true;
  if (!context.mounted) return false;
  final l10n = context.l10n;
  if (await lock.isBiometricEnabled() &&
      await lock.isBiometricAvailable() &&
      await lock.authenticateWithBiometrics(
        reason: l10n.deleteAccountUnlockReason,
      )) {
    return true;
  }
  if (!context.mounted) return false;
  final pin = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      var value = '';
      return AlertDialog(
        title: Text(l10n.appLockCurrentPinTitle),
        content: TextField(
          key: const ValueKey('delete-account-pin'),
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          onChanged: (v) => value = v,
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          decoration: InputDecoration(
            labelText: l10n.appLockCurrentPinLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(value),
            child: Text(l10n.appLockVerify),
          ),
        ],
      );
    },
  );
  if (pin == null) return false;
  final ok = await lock.verifyPin(pin);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.appLockIncorrectPin)));
  }
  return ok;
}

/// Settings > Account > Delete account. Step 1 explains what is deleted;
/// step 2 (after the app lock check) asks for the own handle and, for a
/// registered device, the passphrase.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key, this.reauth = appLockReauth});

  final DeletionReauth reauth;

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  String _handle = '';
  bool _registered = false;
  bool _confirming = false;
  bool _busy = false;
  String _typed = '';
  String _passphrase = '';
  AccountDeletionError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<SecureStorage>();
    final handle = await storage.read('ct_user_handle');
    final account = await storage.getAccountId();
    if (!mounted) return;
    setState(() {
      _handle = handle ?? '';
      _registered = account != null;
    });
  }

  bool get _handleMatches =>
      _handle.isNotEmpty &&
      _typed.trim().toUpperCase() == _handle.trim().toUpperCase();

  bool get _canDelete =>
      !_busy && _handleMatches && (!_registered || _passphrase.isNotEmpty);

  Future<void> _continue() async {
    if (!await widget.reauth(context) || !mounted) return;
    setState(() => _confirming = true);
  }

  Future<void> _delete() async {
    final service = context.read<AccountDeletionService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // On success the service wipes the app and opens onboarding; this
      // screen is gone by then.
      await service.deleteEverything(
        passphrase: _registered ? _passphrase : null,
      );
    } on AccountDeletionException catch (e) {
      if (mounted) setState(() => _error = e.error);
    } catch (_) {
      if (mounted) setState(() => _error = AccountDeletionError.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errorText(
    AppLocalizations l10n,
    AccountDeletionError error,
  ) => switch (error) {
    AccountDeletionError.wrongPassphrase => l10n.deleteAccountWrongPassphrase,
    AccountDeletionError.ownsOrganization => l10n.deleteAccountOwnsOrganization,
    AccountDeletionError.auditor => l10n.deleteAccountAuditor,
    AccountDeletionError.failed => l10n.deleteAccountFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final companion = context.watch<DeviceService?>()?.isCompanion ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.deleteAccountTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.deleteAccountBody(_handle),
                key: const ValueKey('delete-account-body'),
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ),
          if (companion) ...[
            const SizedBox(height: 12),
            Text(l10n.deleteAccountCompanionNote),
          ],
          const SizedBox(height: 24),
          if (!_confirming)
            FilledButton(
              key: const ValueKey('delete-account-continue'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: _continue,
              child: Text(l10n.deleteAccountContinue),
            )
          else ...[
            TextField(
              key: const ValueKey('delete-account-handle'),
              enabled: !_busy,
              autocorrect: false,
              onChanged: (v) => setState(() => _typed = v),
              decoration: InputDecoration(
                labelText: l10n.deleteAccountConfirmLabel(_handle),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_registered) ...[
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('delete-account-passphrase'),
                enabled: !_busy,
                obscureText: true,
                onChanged: (v) => setState(() => _passphrase = v),
                decoration: InputDecoration(
                  labelText: l10n.deleteAccountPassphraseLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const ValueKey('delete-account-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: _canDelete ? _delete : null,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.deleteAccountConfirm),
            ),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Text(
              _errorText(l10n, error),
              key: const ValueKey('delete-account-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          // The same steps without the app (Google's Data safety URL).
          const LegalPageTile(page: LegalPage.deleteAccount),
        ],
      ),
    );
  }
}
