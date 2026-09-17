import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../../core/storage/secure_storage.dart';

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  String? _identity;
  String? _handle;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<SecureStorage>();
    final id = await storage.getDeviceId();
    final handle = await storage.read('ct_user_handle');
    if (mounted) {
      setState(() {
        _handle = handle ?? id;
        _identity = 'ct://$id/${handle ?? id}';
      });
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
            ],
          ],
        ),
      ),
    ),
  );
}
