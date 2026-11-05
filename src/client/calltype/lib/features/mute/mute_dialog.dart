import 'package:calltype_core/network/group_dtos.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import 'mute_controller.dart';

/// Icon for a conversation's mute state, shared by the chat header and the
/// chat list so both say the same thing.
IconData muteIcon(MuteMode mode) => switch (mode) {
  MuteMode.off => Icons.notifications_none_rounded,
  MuteMode.bots => Icons.notifications_paused_outlined,
  MuteMode.all => Icons.notifications_off_outlined,
};

/// Lets the user pick a mute mode and duration. Returns null when cancelled.
Future<MuteSetting?> showMuteDialog(
  BuildContext context, {
  required MuteMode current,
  DateTime Function()? clock,
}) => showDialog<MuteSetting>(
  context: context,
  builder: (_) => _MuteDialog(current: current, clock: clock ?? DateTime.now),
);

class _MuteDialog extends StatefulWidget {
  const _MuteDialog({required this.current, required this.clock});
  final MuteMode current;
  final DateTime Function() clock;

  @override
  State<_MuteDialog> createState() => _MuteDialogState();
}

class _MuteDialogState extends State<_MuteDialog> {
  late MuteMode _mode = widget.current;

  /// 8 hours by default (a working day / a night): a forgotten "forever"
  /// mute silently hides messages for good, so it must be chosen explicitly.
  MuteDuration _duration = MuteDuration.eightHours;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.muteTitle),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<MuteMode>(
              groupValue: _mode,
              onChanged: (m) => setState(() => _mode = m ?? _mode),
              child: Column(
                children: [
                  RadioListTile<MuteMode>(
                    value: MuteMode.off,
                    title: Text(l10n.muteModeOff),
                  ),
                  RadioListTile<MuteMode>(
                    value: MuteMode.bots,
                    title: Text(l10n.muteModeBots),
                    subtitle: Text(l10n.muteModeBotsHint),
                  ),
                  RadioListTile<MuteMode>(
                    value: MuteMode.all,
                    title: Text(l10n.muteModeAll),
                    subtitle: Text(l10n.muteModeAllHint),
                  ),
                ],
              ),
            ),
            // A duration only means something for an actual mute.
            if (_mode != MuteMode.off) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  l10n.muteDurationLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              RadioGroup<MuteDuration>(
                groupValue: _duration,
                onChanged: (d) => setState(() => _duration = d ?? _duration),
                child: Column(
                  children: [
                    for (final d in MuteDuration.values)
                      RadioListTile<MuteDuration>(
                        value: d,
                        title: Text(switch (d) {
                          MuteDuration.oneHour => l10n.muteDurationHour,
                          MuteDuration.eightHours =>
                            l10n.muteDurationEightHours,
                          MuteDuration.oneWeek => l10n.muteDurationWeek,
                          MuteDuration.forever => l10n.muteDurationForever,
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_duration.settingFor(_mode, widget.clock())),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// Opens the dialog for [conversationId] and stores the choice. Used by the
/// header bell and the chat-list long-press, so both behave the same.
Future<void> editMute(
  BuildContext context, {
  required String conversationId,
  required bool group,
}) async {
  final mutes = context.read<MuteController>();
  // Captured before the awaits: the calling widget may be gone afterwards.
  final messenger = ScaffoldMessenger.of(context);
  final failed = context.l10n.muteFailed;
  final choice = await showMuteDialog(
    context,
    current: mutes.modeOf(conversationId),
  );
  if (choice == null) return;
  try {
    await mutes.setMute(
      conversationId: conversationId,
      group: group,
      setting: choice,
    );
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(failed)));
  }
}

/// The bell in a conversation header. Renders nothing when the app tree has
/// no [MuteController] (screens pumped alone in older tests), so adding the
/// feature did not force every existing test to wire it.
class MuteButton extends StatelessWidget {
  const MuteButton({
    super.key,
    required this.conversationId,
    required this.group,
  });

  final String conversationId;
  final bool group;

  @override
  Widget build(BuildContext context) {
    final mutes = context.watch<MuteController?>();
    if (mutes == null) return const SizedBox.shrink();
    final mode = mutes.modeOf(conversationId);
    final l10n = context.l10n;
    return IconButton(
      icon: Icon(muteIcon(mode)),
      tooltip: switch (mode) {
        MuteMode.off => l10n.muteTitle,
        MuteMode.bots => l10n.muteStateBots,
        MuteMode.all => l10n.muteStateAll,
      },
      onPressed: () =>
          editMute(context, conversationId: conversationId, group: group),
    );
  }
}
