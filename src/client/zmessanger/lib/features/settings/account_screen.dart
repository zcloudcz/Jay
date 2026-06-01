import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';

/// Account registration and login screen.
///
/// Toggles between two modes:
///   - **Register** — create a new account with email + passphrase
///   - **Login** — authenticate an existing account
///
/// The passphrase is never sent to the server in plaintext. Instead, it is
/// hashed with SHA-256 to derive an auth key. In production this should use
/// Argon2id for proper password hashing, but SHA-256 serves as a functional
/// placeholder until the Argon2 FFI bridge is integrated.
///
/// On success, the server returns an account ID that enables cloud features
/// (backup, multi-device sync). The account is optional — the app works
/// fully without one.
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
      appBar: AppBar(
        title: Text(_isRegister ? 'Create Account' : 'Log In'),
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
                        'An account enables cloud backup and multi-device sync. '
                        'ZMessanger works fully without one — registration is '
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
                        Icon(Icons.check_circle,
                            color: colorScheme.onPrimaryContainer),
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

  /// Submits the form — either registers or logs in depending on mode.
  ///
  /// Derives an auth key from the passphrase via SHA-256 before sending to
  /// the server. The raw passphrase never leaves the device.
  ///
  /// TODO: Replace SHA-256 with Argon2id for proper password hashing once
  /// the Argon2 FFI bridge is available. SHA-256 is a functional placeholder.
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
      // SHA-256 is used as a placeholder; production should use Argon2id.
      final authKey = sha256.convert(utf8.encode(passphrase)).toString();

      if (_isRegister) {
        await apiClient.registerAccount(email: email, authKey: authKey);
        if (mounted) {
          setState(() {
            _successMessage =
                'Account created. Cloud backup enabled.';
            _isLoading = false;
          });
        }
      } else {
        await apiClient.login(email: email, authKey: authKey);
        if (mounted) {
          setState(() {
            _successMessage =
                'Logged in. Cloud backup enabled.';
            _isLoading = false;
          });
        }
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
