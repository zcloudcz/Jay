import 'package:flutter/material.dart';

import '../app.dart';
import '../session.dart';
import '../ui/format.dart';

/// E-mail + passphrase + TOTP (or backup code). On success the router's
/// redirect sends the operator back to `from` (the route they were on when
/// the session ended), so nothing here navigates.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _passphrase = TextEditingController();
  final _code = TextEditingController();
  bool _useBackup = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _passphrase.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final session = AdminScope.of(context).session;
    final l = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.login(
        email: _email.text,
        passphrase: _passphrase.text,
        code: _useBackup ? null : _code.text,
        backupCode: _useBackup ? _code.text : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(l, e);
        _busy = false;
        // A TOTP code is single-use; a wrong one must be retyped anyway.
        _code.clear();
      });
      return;
    }
    // Never keep the passphrase in a controller longer than needed.
    _passphrase.clear();
    _code.clear();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final session = AdminScope.of(context).session;
    final banner = switch (session.lastReason) {
      LogoutReason.expired => l.loginExpired,
      LogoutReason.unauthorized => l.loginUnauthorized,
      LogoutReason.manual => l.loginLoggedOut,
      LogoutReason.none => null,
    };
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _form,
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(l.appTitle, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary)),
                        const SizedBox(height: 4),
                        Text(l.loginTitle, style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        Text(l.loginNote, style: Theme.of(context).textTheme.bodySmall),
                        if (banner != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            key: const Key('login-banner'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(banner, style: TextStyle(color: scheme.onSecondaryContainer)),
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('login-email'),
                          controller: _email,
                          decoration: InputDecoration(labelText: l.loginEmail),
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username, AutofillHints.email],
                          validator: (v) => (v ?? '').trim().isEmpty ? l.loginEmailRequired : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('login-passphrase'),
                          controller: _passphrase,
                          obscureText: true,
                          decoration: InputDecoration(labelText: l.loginPassphrase),
                          autofillHints: const [AutofillHints.password],
                          validator: (v) => (v ?? '').isEmpty ? l.loginPassphraseRequired : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('login-code'),
                          controller: _code,
                          decoration: InputDecoration(labelText: _useBackup ? l.loginBackupCode : l.loginCode),
                          autofillHints: const [AutofillHints.oneTimeCode],
                          keyboardType: _useBackup ? TextInputType.text : TextInputType.number,
                          validator: (v) => (v ?? '').trim().isEmpty ? l.loginCodeRequired : null,
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            key: const Key('login-toggle-backup'),
                            onPressed: () => setState(() {
                              _useBackup = !_useBackup;
                              _code.clear();
                            }),
                            child: Text(_useBackup ? l.loginUseTotp : l.loginUseBackup),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            key: const Key('login-error'),
                            style: TextStyle(color: scheme.error),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          key: const Key('login-submit'),
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(l.loginSubmit),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
