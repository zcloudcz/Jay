import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';
import '../../core/network/backup_api.dart';
import '../../core/storage/secure_storage.dart';

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
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

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
  String? _error;
  String? _successMessage;

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

    return Scaffold(
      appBar: AppBar(title: Text(_isRegister ? 'Create Account' : 'Log In')),
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
                          Text(
                            'Optional Account',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'An account enables encrypted cloud backups. '
                        'Jay works fully without one — registration is '
                        'completely optional.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // -- Email field -----------------------------------------------
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'your@email.com',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Email is required';
                  }
                  // Basic email format check — server validates more thoroughly.
                  if (!value.contains('@') || !value.contains('.')) {
                    return 'Enter a valid email address';
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
                decoration: const InputDecoration(
                  labelText: 'Passphrase',
                  hintText: 'Choose a strong passphrase',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Passphrase is required';
                  }
                  if (value.length < 8) {
                    return 'Passphrase must be at least 8 characters';
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
                    : Text(_isRegister ? 'Create Account' : 'Log In'),
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
                            _error = null;
                            _successMessage = null;
                          });
                        },
                  child: Text(
                    _isRegister
                        ? 'Already have an account? Log in'
                        : 'Need an account? Register',
                  ),
                ),
              ),

              // -- Success message -------------------------------------------
              if (_successMessage != null) ...[
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
                            _successMessage!,
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

              // -- Error message ---------------------------------------------
              if (_error != null) ...[
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
                            _error!,
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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _successMessage = null;
    });

    try {
      final apiClient = context.read<ApiClient>();
      final email = _emailController.text.trim();
      final passphrase = _passphraseController.text;

      // Derive auth key from passphrase — server never sees the raw passphrase.
      // Retain the credential encoding used by existing registered accounts.
      final authKey = sha256.convert(utf8.encode(passphrase)).toString();

      final storage = context.read<SecureStorage>();
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
      if (mounted) {
        _passphraseController.clear();
        setState(() {
          _successMessage = 'Account linked. Cloud backup enabled.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }
}
