import '../calltype_bot.dart';

/// Env `BOT_INBOUND`: `owners` (default) or `open`.
const botInboundEnv = 'BOT_INBOUND';

/// Publishes the server-side inbound policy at start (spec
/// 2026-11-09-bot-access A3): only [owners] (resolved handles) may reach the
/// bot through the server, unless [inbound] (env `BOT_INBOUND`) is `open`.
///
/// WHY never fatal: the bot still filters every sender itself before
/// decryption, the server policy only saves the server (and the bot's
/// queue) from strangers. An old server answers 404, which is logged.
/// An unknown `BOT_INBOUND` value falls back to `owners` (fail closed).
Future<void> publishInboundPolicy(
  CallTypeBot bot, {
  required Iterable<String> owners,
  String? inbound,
  required void Function(String) log,
}) async {
  final raw = inbound?.trim().toLowerCase() ?? '';
  final open = raw == 'open';
  if (raw.isNotEmpty && !open && raw != 'owners') {
    log('$botInboundEnv="$inbound" is unknown; using "owners".');
  }
  try {
    final stored = await bot.setInboundPolicy(
      ownersOnly: !open,
      owners: owners,
    );
    log(
      open
          ? 'Inbound policy: open (anyone can reach the bot through the server).'
          : 'Inbound policy: owners only (${stored.join(', ')}) and groups '
                'with one of them.',
    );
  } catch (e) {
    log(
      CallTypeBot.isNotFound(e)
          ? 'Server has no bot inbound policy yet; the bot filters senders itself.'
          : 'Publishing the inbound policy failed ($e); the bot filters '
                'senders itself.',
    );
  }
}
