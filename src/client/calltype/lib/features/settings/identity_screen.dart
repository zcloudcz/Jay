import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';

/// Key display names live under in secure storage, same tier as the device
/// id/secret — it is small, sensitive-ish (identifying) data, not a bulk
/// table row.
const _keyDisplayName = 'ct_display_name';

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  String? _identity;
  String? _handle;
  String? _deviceId;
  final _nameController = TextEditingController();
  bool _savingName = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final storage = context.read<SecureStorage>();
    final id = await storage.getDeviceId();
    final handle = await storage.read('ct_user_handle');
    final displayName = await storage.read(_keyDisplayName);
    if (mounted) {
      setState(() {
        _deviceId = id;
        _handle = handle ?? id;
        _identity = 'ct://$id/${handle ?? id}';
        _nameController.text = displayName ?? '';
      });
    }
  }

  Future<void> _saveDisplayName() async {
    final deviceId = _deviceId;
    if (deviceId == null || _savingName) return;
    final name = _nameController.text.trim();

    setState(() => _savingName = true);
    // Grab both before the first await — using `context` after an await
    // needs a `mounted` check, so it's simpler to read them up front.
    final api = context.read<ApiClient>();
    final storage = context.read<SecureStorage>();
    try {
      await api.updateDisplayName(
        deviceId: deviceId,
        displayName: name.isEmpty ? null : name,
      );
      await storage.write(_keyDisplayName, name);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.identityDisplayNameSaveFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.identityTitle)),
    body: Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_identity == null)
              const CircularProgressIndicator()
            else ...[
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: QrImageView(data: _identity!, size: 240),
              ),
              const SizedBox(height: 24),
              SelectableText(_handle ?? ''),
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(context.l10n.identityCopyInvite),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _identity!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l10n.identityInviteCopied)),
                    );
                  }
                },
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TextField(
                  controller: _nameController,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: context.l10n.identityDisplayNameLabel,
                    helperText: context.l10n.identityDisplayNameHint,
                    helperMaxLines: 3,
                    suffixIcon: _savingName
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : const Icon(Icons.check),
                  ),
                  onSubmitted: (_) => _saveDisplayName(),
                  onTapOutside: (_) => _saveDisplayName(),
                  textInputAction: TextInputAction.done,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
