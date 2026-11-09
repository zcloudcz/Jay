import 'package:flutter/foundation.dart';

/// The Jay API the app talks to. Same `--dart-define` as main.dart's
/// `baseUrl`, read again here so the wizard needs no new provider.
const appApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

/// Where the setup scripts are served (web/bots -> infra/bots).
const botScriptsBaseUrl = 'https://jay.zcloud.cz/bots';

/// What answers the bot's messages (spec 2026-11-09-bot-factory, B6/B7).
enum BotProvider {
  anthropic('anthropic'),
  openai('openai'),
  claudeCli('claude-cli'),
  codexCli('codex-cli'),
  hermes('hermes');

  const BotProvider(this.id);

  /// The script's `--provider` value.
  final String id;

  /// Runs the owner's own signed-in vendor CLI (subscription).
  bool get isSubscription => this == claudeCli || this == codexCli;

  /// The script asks for a key on the target computer.
  bool get asksForKey => !isSubscription;
}

/// Where the bot runs.
enum BotTarget { linux, macos, windows, docker }

/// Bot names: what the scripts accept (1..40 characters, no control
/// characters, at least one letter or digit for the folder name).
bool isValidBotName(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > 40) return false;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(n)) return false;
  return RegExp(r'[A-Za-z0-9]').hasMatch(_stripAccents(n));
}

/// Mirrors the scripts' accent folding just enough to judge a name.
String _stripAccents(String s) => s
    .replaceAll(RegExp('[áàâäãåÁÀÂÄÃÅ]'), 'a')
    .replaceAll(RegExp('[čćçČĆÇ]'), 'c')
    .replaceAll(RegExp('[ďĎ]'), 'd')
    .replaceAll(RegExp('[éèêëěÉÈÊËĚ]'), 'e')
    .replaceAll(RegExp('[íìîïÍÌÎÏ]'), 'i')
    .replaceAll(RegExp('[ľĺĽĹ]'), 'l')
    .replaceAll(RegExp('[ňñŇÑ]'), 'n')
    .replaceAll(RegExp('[óòôöõÓÒÔÖÕ]'), 'o')
    .replaceAll(RegExp('[řŕŘŔ]'), 'r')
    .replaceAll(RegExp('[šŠ]'), 's')
    .replaceAll(RegExp('[ťŤ]'), 't')
    .replaceAll(RegExp('[úùûüůÚÙÛÜŮ]'), 'u')
    .replaceAll(RegExp('[ýÿÝ]'), 'y')
    .replaceAll(RegExp('[žŽ]'), 'z');

/// POSIX shell single quotes: the only character that needs care is `'`
/// itself (close, escaped quote, reopen). Nothing inside is expanded.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// PowerShell single quotes: `'` is doubled, nothing else is special.
/// WHY not double quotes: those expand `$var` and `$(...)`, which a bot
/// name could smuggle in.
String powerShellQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// The ONE command the user runs on the bot's computer.
///
/// Holds no secret: the API key is asked for (hidden) by the script on that
/// computer, so it never passes through Jay, a clipboard history or a
/// shell history. Every user-provided value is quoted for the target shell.
String newBotCommand({
  required String name,
  required String ownerHandle,
  required String apiBaseUrl,
  required BotProvider provider,
  required BotTarget target,
  String scriptsBaseUrl = botScriptsBaseUrl,
}) {
  final n = name.trim();
  final owner = ownerHandle.trim().toUpperCase();
  final api = apiBaseUrl.endsWith('/')
      ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
      : apiBaseUrl;
  if (target == BotTarget.windows) {
    return '& ([scriptblock]::Create((irm $scriptsBaseUrl/new-bot.ps1))) '
        '-Name ${powerShellQuote(n)} -Owner ${powerShellQuote(owner)} '
        '-Provider ${provider.id} -Api ${powerShellQuote(api)}';
  }
  final docker = target == BotTarget.docker ? ' --docker' : '';
  return 'curl -fsSL $scriptsBaseUrl/new-bot.sh | bash -s -- '
      '--name ${shellQuote(n)} --owner ${shellQuote(owner)} '
      '--provider ${provider.id} --api ${shellQuote(api)}$docker';
}

/// The target preselected for this device: the computer the user is on
/// (also when Jay runs in its browser). A phone cannot host a bot, so on
/// Android/iOS Linux is offered, the most common always-on machine.
BotTarget defaultBotTarget(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows => BotTarget.windows,
  TargetPlatform.macOS => BotTarget.macos,
  _ => BotTarget.linux,
};

/// Docker runs only the API providers: the subscription CLIs need the
/// owner's own sign-in on the host itself.
bool isSupportedCombination(BotProvider provider, BotTarget target) =>
    !(target == BotTarget.docker && provider.isSubscription);
