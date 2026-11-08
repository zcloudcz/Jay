import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/backup_api.dart';
import 'package:calltype_core/storage/database.dart';
import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../devices/device_service.dart';
import '../devices/link_ux.dart';
import '../organization/mfa_section.dart';

/// Account registration and login screen.
///
/// Toggles between two modes:
///   - **Register** — create a new account with email + passphrase
///   - **Login** — authenticate an existing account
///
/// The client sends the existing SHA-256 credential format over TLS;
/// the server hashes this credential with salted Argon2id.
/// A successful login is followed by authenticated device linking before
/// cloud backups become available locally.
///
/// Once the device is linked to an account, the screen also shows the account
/// id (copyable) and the TOTP [MfaSection]: a plain registered account needs
/// MFA to sign in to the moderation web, not only organization admins.
///
/// Link UX A4: on web and desktop a login that leaves this device without
/// conversations explains why (the account holds backups only, by design of
/// spec 1) and offers the way that does work: linking with the phone.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, this.linkFirstPlatform});

  /// Overrides [isLinkFirstPlatform] (tests run on one platform only).
  final bool? linkFirstPlatform;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _emailController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  /// True = register mode, false = login mode.
  bool _isRegister = true;
  bool _isLoading = false;
  // Flags, not texts: the messages are looked up in build() so they follow
  // the current locale.
  bool _error = false;
  bool _success = false;

  /// A login left this device without conversations (link UX, A4).
  bool _noChatsAfterLogin = false;

  /// Linked account of this device (null = not registered). Loaded once and
  /// set again after a successful register/login below.
  String? _accountId;

  @override
  void initState() {
    super.initState();
    context.read<SecureStorage>().getAccountId().then((id) {
      if (mounted && id != null) setState(() => _accountId = id);
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isRegister ? l10n.accountCreateTitle : l10n.accountLoginTitle,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // -- Explanation card -------------------------------------------
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: colorScheme.primary),
                          const SizedBox(width: 8),
                          // Expanded: translated headings may need to wrap.
                          Expanded(
                            child: Text(
                              l10n.accountOptionalTitle,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.accountOptionalBody,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // -- Registered account: id + MFA ------------------------------
              if (_accountId case final accountId?) ...[
                _AccountInfoCard(accountId: accountId),
                const SizedBox(height: 16),
                Text(
                  l10n.accountMfaExplainer,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                // Keyed by id: a login into another account must rebuild the
                // section so its controller loads that account's status.
                MfaSection(key: ValueKey(accountId), accountId: accountId),
                const SizedBox(height: 24),
              ],

              // -- Email field -----------------------------------------------
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: l10n.accountEmailLabel,
                  hintText: l10n.accountEmailHint,
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return l10n.accountEmailRequired;
                  }
                  // Basic email format check — server validates more thoroughly.
                  if (!value.contains('@') || !value.contains('.')) {
                    return l10n.accountEmailInvalid;
                  }
                  return null;
                },
                enabled: !_isLoading,
              ),
              const SizedBox(height: 16),

              // -- Passphrase field ------------------------------------------
              TextFormField(
                controller: _passphraseController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.accountPassphraseLabel,
                  hintText: l10n.accountPassphraseHint,
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return l10n.accountPassphraseRequired;
                  }
                  if (value.length < 8) {
                    return l10n.accountPassphraseTooShort;
                  }
                  return null;
                },
                enabled: !_isLoading,
              ),
              const SizedBox(height: 24),

              // -- Submit button ---------------------------------------------
              FilledButton(
                onPressed: _isLoading ? null : _submit,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _isRegister
                            ? l10n.accountCreateTitle
                            : l10n.accountLoginTitle,
                      ),
              ),
              const SizedBox(height: 16),

              // -- Mode toggle -----------------------------------------------
              // TextButton to switch between register and login modes. Placed
              // below the submit button following standard auth screen patterns.
              Center(
                child: TextButton(
                  onPressed: _isLoading
                      ? null
                      : () {
                          setState(() {
                            _isRegister = !_isRegister;
                            _error = false;
                            _success = false;
                            _noChatsAfterLogin = false;
                          });
                        },
                  child: Text(
                    _isRegister
                        ? l10n.accountSwitchToLogin
                        : l10n.accountSwitchToRegister,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

              // -- Success message -------------------------------------------
              if (_success) ...[
                const SizedBox(height: 16),
                Card(
                  color: colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.accountLinked,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // -- Why there are no chats (link UX, A4) ------------------------
              if (_noChatsAfterLogin) ...[
                const SizedBox(height: 16),
                const NoChatsAfterLoginCard(),
              ],

              // -- Error message ---------------------------------------------
              if (_error) ...[
                const SizedBox(height: 16),
                Card(
                  color: colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: colorScheme.error),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.accountFailed,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onErrorContainer,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Web or desktop, not linked yet, and not a single conversation here.
  /// Optional providers: the screen is also pumped without them in tests.
  Future<bool> _deviceHasNoChats(
    AppDatabase? db,
    DeviceService? devices,
  ) async {
    if (!(widget.linkFirstPlatform ?? isLinkFirstPlatform)) return false;
    if (db == null || (devices?.isCompanion ?? false)) return false;
    try {
      return (await (db.select(db.conversations)..limit(1)).get()).isEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = false;
      _success = false;
      _noChatsAfterLogin = false;
    });

    try {
      final apiClient = context.read<ApiClient>();
      final email = _emailController.text.trim();
      final passphrase = _passphraseController.text;

      // Derive auth key from passphrase — server never sees the raw passphrase.
      // Retain the credential encoding used by existing registered accounts.
      final authKey = sha256.convert(utf8.encode(passphrase)).toString();

      final storage = context.read<SecureStorage>();
      final db = context.read<AppDatabase?>();
      final devices = context.read<DeviceService?>();
      final deviceId = await storage.getDeviceId();
      if (deviceId == null) {
        throw StateError('Set up this device before linking an account.');
      }
      final response = _isRegister
          ? await apiClient.registerAccount(email: email, authKey: authKey)
          : await apiClient.login(email: email, authKey: authKey);
      final accountId = response['accountId'] as String;
      await apiClient.linkAccountDevice(accountId, deviceId, authKey);
      await storage.setAccountId(accountId);
      final noChats = !_isRegister && await _deviceHasNoChats(db, devices);
      if (mounted) {
        _passphraseController.clear();
        setState(() {
          _success = true;
          _isLoading = false;
          _accountId = accountId;
          _noChatsAfterLogin = noChats;
        });
      }
    } catch (_) {
      // The exception text (Dio / StateError) is developer-facing; the user
      // gets one localized, actionable message.
      if (mounted) {
        setState(() {
          _error = true;
          _isLoading = false;
        });
      }
    }
  }
}

/// Explains, after a login, why this browser or computer shows no chats and
/// links to the screen that brings them (link UX, A4).
class NoChatsAfterLoginCard extends StatelessWidget {
  const NoChatsAfterLoginCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.accountNoChatsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l10n.accountNoChatsBody),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.push('/settings/devices/link'),
              icon: const Icon(Icons.phonelink_rounded),
              label: Text(l10n.accountNoChatsAction),
            ),
          ],
        ),
      ),
    );
  }
}

/// "This device is linked to an account" with the account id in small,
/// secondary text and a copy button (the id is what support or the operator
/// configuration may ask for).
class _AccountInfoCard extends StatelessWidget {
  const _AccountInfoCard({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.accountInfoTitle, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l10n.accountIdLabel, style: secondary),
            Row(
              children: [
                Expanded(child: SelectableText(accountId, style: secondary)),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  visualDensity: VisualDensity.compact,
                  tooltip: l10n.accountIdCopy,
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: accountId));
                    messenger.showSnackBar(
                      SnackBar(content: Text(l10n.accountIdCopied)),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
