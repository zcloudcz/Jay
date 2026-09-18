import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import 'emergency_controller.dart';

/// "I have an emergency code" (Settings → Organization → this screen, E07
/// deliverable 5). Deliberately independent of any organization membership —
/// spec 2.3's whole point is that a device with no working account/SSO can
/// still join the emergency conversation via a code alone.
class EmergencyEnrollScreen extends StatefulWidget {
  const EmergencyEnrollScreen({super.key});

  @override
  State<EmergencyEnrollScreen> createState() => _EmergencyEnrollScreenState();
}

class _EmergencyEnrollScreenState extends State<EmergencyEnrollScreen> {
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EmergencyEnrollController>();
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.emergencyHaveCode)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _codeController,
              decoration: InputDecoration(labelText: l10n.emergencyEnrollCodeLabel),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: controller.isLoading
                  ? null
                  : () async {
                      await controller.enroll(
                        _codeController.text.trim(),
                        fallbackTitle: l10n.emergencyTitle,
                      );
                      if (!context.mounted) return;
                      if (controller.enrolledOrganizationId != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.emergencyEnrollSuccess)),
                        );
                        // Land straight in the emergency conversation when the
                        // server returned its group id; the chat list is only
                        // a fallback for the pre-existing edge case where it
                        // didn't (no auditor configured yet — see EmergencyEndpoints.Enroll).
                        context.go(
                          controller.enrolledConversationId != null
                              ? '/chats/${controller.enrolledConversationId}'
                              : '/chats',
                        );
                      } else if (controller.errorCode != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.emergencyEnrollFailed)),
                        );
                      }
                    },
              child: Text(l10n.emergencyEnrollButton),
            ),
          ],
        ),
      ),
    );
  }
}
