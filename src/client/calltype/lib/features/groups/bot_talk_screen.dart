import 'package:calltype_core/network/group_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../shared/widgets/bot_badge.dart';
import 'bot_talk_controller.dart';

/// Group "Bot conversation" setting (spec D1-D4): may the bots of this group
/// talk to each other, which of them, how long and how often.
///
/// One screen for admins and everybody else: non-admins see the same values
/// disabled. Showing the setting read-only matters, because it explains why
/// the bots in the group do (or do not) answer each other.
class BotTalkScreen extends StatefulWidget {
  const BotTalkScreen({super.key});

  @override
  State<BotTalkScreen> createState() => _BotTalkScreenState();
}

class _BotTalkScreenState extends State<BotTalkScreen> {
  final _turns = TextEditingController();
  final _pause = TextEditingController();
  int _seenDraft = -1;

  @override
  void initState() {
    super.initState();
    final controller = context.read<BotTalkController>();
    if (controller.loading) controller.load();
  }

  @override
  void dispose() {
    _turns.dispose();
    _pause.dispose();
    super.dispose();
  }

  String _errorText(BotTalkError error) {
    final l10n = context.l10n;
    return switch (error) {
      BotTalkError.forbidden => l10n.botTalkReadOnly,
      BotTalkError.notABotMember => l10n.botTalkErrorNotABot,
      BotTalkError.invalid => l10n.botTalkErrorInvalid,
      BotTalkError.failed => l10n.botTalkErrorFailed,
    };
  }

  Future<void> _save(BotTalkController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    // Invalid fields already show their own error under the input; a
    // snackbar on top would only repeat it.
    if (!controller.maxTurnsValid || !controller.pauseValid) return;
    final error = await controller.save();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(error == null ? l10n.botTalkSaved : _errorText(error)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<BotTalkController>();
    final l10n = context.l10n;
    // The text controllers live here (they need dispose); refill them only
    // when the controller replaced the draft, never on every keystroke, or
    // the cursor would jump.
    if (_seenDraft != controller.draftVersion) {
      _seenDraft = controller.draftVersion;
      _turns.text = controller.maxTurnsText;
      _pause.text = controller.pauseText;
    }
    final editable = controller.canEdit && !controller.saving;
    final Widget body;
    if (controller.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (controller.loadFailed) {
      body = Center(
        child: TextButton(
          onPressed: controller.load,
          child: Text(l10n.botTalkLoadFailed, textAlign: TextAlign.center),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(l10n.botTalkIntro),
          ),
          if (!controller.canEdit)
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: Text(l10n.botTalkReadOnly),
            ),
          RadioGroup<BotTalkMode>(
            groupValue: controller.mode,
            onChanged: (m) {
              if (m != null) controller.setMode(m);
            },
            child: Column(
              children: [
                RadioListTile<BotTalkMode>(
                  value: BotTalkMode.off,
                  enabled: editable,
                  title: Text(l10n.botTalkModeOff),
                  subtitle: Text(l10n.botTalkModeOffHint),
                ),
                RadioListTile<BotTalkMode>(
                  value: BotTalkMode.all,
                  enabled: editable,
                  title: Text(l10n.botTalkModeAll),
                  subtitle: Text(l10n.botTalkModeAllHint),
                ),
                RadioListTile<BotTalkMode>(
                  value: BotTalkMode.selected,
                  enabled: editable,
                  title: Text(l10n.botTalkModeSelected),
                  subtitle: Text(l10n.botTalkModeSelectedHint),
                ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.botTalkBotsHeader,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (controller.bots.isEmpty)
            ListTile(title: Text(l10n.botTalkNoBots))
          else
            for (final bot in controller.bots)
              CheckboxListTile(
                key: ValueKey('bot-${bot.deviceId}'),
                value: controller.isSelected(bot.deviceId),
                // Checkboxes only matter for "Selected bots"; in the other
                // modes they stay visible (so the list is not lost when the
                // admin switches back) but cannot be changed.
                onChanged: editable && controller.mode == BotTalkMode.selected
                    ? (on) => controller.toggleBot(bot.deviceId, on ?? false)
                    : null,
                title: NameWithBotBadge(
                  name: bot.displayName ?? bot.userHandle ?? bot.deviceId,
                  isBot: true,
                ),
                subtitle: bot.displayName != null && bot.userHandle != null
                    ? Text(bot.userHandle!)
                    : null,
              ),
          const Divider(),
          // T3/T4 (spec 2026-11-13-group-topics row 15): how the bots treat
          // people's messages, independent of the bot-to-bot mode above.
          SwitchListTile(
            key: const ValueKey('bot-talk-read-all'),
            value: controller.botsReadAll,
            onChanged: editable ? controller.setBotsReadAll : null,
            title: Text(l10n.botTalkReadAllTitle),
            subtitle: Text(l10n.botTalkReadAllHint),
          ),
          SwitchListTile(
            key: const ValueKey('bot-talk-reply-without-mention'),
            value: controller.replyWithoutMention,
            onChanged: editable ? controller.setReplyWithoutMention : null,
            title: Text(l10n.botTalkReplyWithoutMentionTitle),
            subtitle: Text(l10n.botTalkReplyWithoutMentionHint),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              key: const ValueKey('bot-talk-max-turns'),
              controller: _turns,
              enabled: editable,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: controller.setMaxTurnsText,
              decoration: InputDecoration(
                labelText: l10n.botTalkMaxTurnsLabel,
                helperText: l10n.botTalkMaxTurnsHelp,
                errorText: controller.maxTurnsValid
                    ? null
                    : l10n.botTalkMaxTurnsInvalid,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              key: const ValueKey('bot-talk-pause'),
              controller: _pause,
              enabled: editable,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: controller.setPauseText,
              decoration: InputDecoration(
                labelText: l10n.botTalkPauseLabel,
                helperText: l10n.botTalkPauseHelp,
                errorText: controller.pauseValid
                    ? null
                    : l10n.botTalkPauseInvalid,
              ),
            ),
          ),
          if (controller.canEdit)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed:
                    editable &&
                        controller.maxTurnsValid &&
                        controller.pauseValid
                    ? () => _save(controller)
                    : null,
                child: Text(l10n.commonSave),
              ),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.botTalkTitle)),
      body: body,
    );
  }
}
