import 'package:calltype_core/network/emergency_api.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/network/api_client.dart';
import '../../../core/network/signalr_client.dart';
import '../../../l10n/l10n.dart';

/// Shows the drill confirm dialog anywhere in the app when the server pushes
/// the `EmergencyDrill` hub event (E07), same pattern as [SessionOverlay]'s
/// app-wide incoming-call handling — kept as its own widget rather than
/// growing SessionOverlay's already-large state machine.
class EmergencyDrillOverlay extends StatefulWidget {
  const EmergencyDrillOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<EmergencyDrillOverlay> createState() => _EmergencyDrillOverlayState();
}

class _EmergencyDrillOverlayState extends State<EmergencyDrillOverlay> {
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    context.read<SignalRClient>().onEmergencyDrill.listen(_onDrill);
  }

  void _onDrill(Map<String, dynamic> event) {
    if (!mounted || _dialogOpen) return;
    final organizationId = event['organizationId'] as String?;
    final drillId = event['drillId'];
    if (organizationId == null || drillId == null) return;
    _dialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _dialogOpen = false;
        return;
      }
      final l10n = context.l10n;
      final api = context.read<ApiClient>();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.emergencyDrillPromptTitle),
          content: Text(l10n.emergencyDrillPromptBody),
          actions: [
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                try {
                  await api.confirmEmergencyDrill(
                    organizationId,
                    drillId is int ? drillId : int.parse(drillId.toString()),
                  );
                } catch (_) {
                  // Best-effort: a failed confirm just means this drill's
                  // reachability count misses this device — no user-facing
                  // error worth interrupting them with here.
                }
              },
              child: Text(l10n.emergencyDrillConfirmButton),
            ),
          ],
        ),
      );
      _dialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
