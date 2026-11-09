import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/storage/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../devices/device_service.dart';
import 'new_bot_command.dart';

/// The handle a bot must answer: the user's identity. A companion device
/// (linked web/desktop) is not an identity of its own, so it hands out the
/// primary's handle, like the identity screen does.
Future<String?> loadOwnerHandle(BuildContext context) async {
  final storage = context.read<SecureStorage>();
  final devices = context.read<DeviceService>();
  if (devices.isCompanion) return devices.linkedPrimaryHandle();
  return storage.read('ct_user_handle');
}

/// "New bot" wizard (spec 2026-11-09-bot-factory, B7): name, what answers,
/// where it runs -> ONE command to paste on that computer.
///
/// No server call and no key field anywhere: the bot's keys are created on
/// the computer that runs it (E2E), and the provider key is typed there,
/// into the script's hidden prompt, never into Jay.
class NewBotScreen extends StatefulWidget {
  const NewBotScreen({
    super.key,
    this.ownerHandleLoader,
    this.apiBaseUrl = appApiBaseUrl,
    this.platform,
  });

  /// Test seam; defaults to [loadOwnerHandle].
  final Future<String?> Function(BuildContext context)? ownerHandleLoader;
  final String apiBaseUrl;

  /// Test seam for the preselected target; defaults to the running
  /// platform (in a browser: the browser's OS).
  final TargetPlatform? platform;

  @override
  State<NewBotScreen> createState() => _NewBotScreenState();
}

class _NewBotScreenState extends State<NewBotScreen> {
  final _name = TextEditingController();
  BotProvider _provider = BotProvider.anthropic;
  late BotTarget _target = defaultBotTarget(
    widget.platform ?? defaultTargetPlatform,
  );
  String? _owner;
  bool _loaded = false;
  bool _showResult = false;
  bool _nameTouched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final owner = await (widget.ownerHandleLoader ?? loadOwnerHandle)(
        context,
      );
      if (mounted) {
        setState(() {
          _owner = owner;
          _loaded = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _nameOk => isValidBotName(_name.text);

  String get _command => newBotCommand(
    name: _name.text,
    ownerHandle: _owner!,
    apiBaseUrl: widget.apiBaseUrl,
    provider: _provider,
    target: _target,
  );

  void _selectTarget(BotTarget target) => setState(() {
    _target = target;
    // Docker cannot host a subscription CLI; fall back to an API key.
    if (!isSupportedCombination(_provider, target)) {
      _provider = BotProvider.anthropic;
    }
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.newBotTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _owner == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.newBotNoHandle, textAlign: TextAlign.center),
              ),
            )
          : _showResult
          ? _result(context)
          : _form(context),
    );
  }

  Widget _form(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    String providerLabel(BotProvider p) => switch (p) {
      BotProvider.anthropic => l10n.newBotProviderAnthropic,
      BotProvider.openai => l10n.newBotProviderOpenai,
      BotProvider.claudeCli => l10n.newBotProviderClaudeCli,
      BotProvider.codexCli => l10n.newBotProviderCodexCli,
      BotProvider.hermes => l10n.newBotProviderHermes,
    };
    String targetLabel(BotTarget t) => switch (t) {
      BotTarget.linux => l10n.newBotTargetLinux,
      BotTarget.macos => l10n.newBotTargetMacos,
      BotTarget.windows => l10n.newBotTargetWindows,
      BotTarget.docker => l10n.newBotTargetDocker,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const ValueKey('new-bot-name'),
          controller: _name,
          maxLength: 40,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.newBotNameLabel,
            helperText: l10n.newBotNameHint,
            errorText: _nameTouched && !_nameOk ? l10n.newBotNameInvalid : null,
          ),
          onChanged: (_) => setState(() => _nameTouched = true),
        ),
        const SizedBox(height: 16),
        Text(l10n.newBotProviderTitle, style: theme.textTheme.titleSmall),
        RadioGroup<BotProvider>(
          groupValue: _provider,
          onChanged: (p) => setState(() => _provider = p ?? _provider),
          child: Column(
            children: [
              for (final p in BotProvider.values)
                RadioListTile<BotProvider>(
                  key: ValueKey('new-bot-provider-${p.id}'),
                  value: p,
                  enabled: isSupportedCombination(p, _target),
                  title: Text(providerLabel(p)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.newBotTargetTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final t in BotTarget.values)
              ChoiceChip(
                key: ValueKey('new-bot-target-${t.name}'),
                label: Text(targetLabel(t)),
                selected: _target == t,
                onSelected: (_) => _selectTarget(t),
              ),
          ],
        ),
        if (_target == BotTarget.docker) ...[
          const SizedBox(height: 8),
          Text(l10n.newBotNoteDockerCli, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('new-bot-show-command'),
          onPressed: _nameOk ? () => setState(() => _showResult = true) : null,
          child: Text(l10n.newBotShowCommand),
        ),
      ],
    );
  }

  Widget _result(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final command = _command;
    final steps = [
      _target == BotTarget.windows
          ? l10n.newBotStepPowerShell
          : l10n.newBotStepTerminal,
      if (_provider.asksForKey) l10n.newBotStepKey,
      l10n.newBotStepWait,
    ];
    // Who can reach the bot and who pays (spec 2026-11-09-bot-access A8).
    // Subscription bots answer only the owner unless the command opts in.
    final access = switch (_provider) {
      BotProvider.claudeCli || BotProvider.codexCli => l10n.newBotAccessCli(
        _target == BotTarget.windows
            ? '-GroupReplies members'
            : '--group-replies members',
      ),
      BotProvider.hermes => l10n.newBotAccessHermes,
      _ => l10n.newBotAccessApi,
    };
    final note = switch (_provider) {
      BotProvider.claudeCli => l10n.newBotNoteClaudeCli,
      BotProvider.codexCli => l10n.newBotNoteCodexCli,
      BotProvider.hermes => l10n.newBotNoteHermes,
      _ => null,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l10n.newBotCommandTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        if (note != null) ...[
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(note, key: const ValueKey('new-bot-note')),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            command,
            key: const ValueKey('new-bot-command'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('new-bot-copy'),
            icon: const Icon(Icons.copy_rounded),
            label: Text(l10n.newBotCopy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l10n.newBotCopied)));
              }
            },
          ),
        ),
        const SizedBox(height: 16),
        for (final (i, step) in steps.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
            title: Text(step),
          ),
        const SizedBox(height: 8),
        Text(
          access,
          key: const ValueKey('new-bot-access'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          _target == BotTarget.windows
              ? l10n.newBotUpdateHintWindows
              : l10n.newBotUpdateHint,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _showResult = false),
            child: Text(l10n.newBotBack),
          ),
        ),
      ],
    );
  }
}

/// Settings -> Bots: what a bot is and the way to create one. There is no
/// server-side list of "my bots" yet (spec B8), so this is an entry point.
class BotsScreen extends StatelessWidget {
  const BotsScreen({super.key, this.onNewBot});

  /// Test seam; defaults to pushing the wizard route.
  final VoidCallback? onNewBot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.botsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.botsIntro, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              key: const ValueKey('bots-new-bot'),
              leading: Icon(
                Icons.smart_toy_outlined,
                color: theme.colorScheme.primary,
              ),
              title: Text(l10n.botsNewBot),
              subtitle: Text(l10n.botsNewBotSubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onNewBot ?? () => context.push('/settings/bots/new'),
            ),
          ),
        ],
      ),
    );
  }
}
