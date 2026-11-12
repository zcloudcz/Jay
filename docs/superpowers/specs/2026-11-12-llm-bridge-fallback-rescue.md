# llm_bridge: fallback providers and a rescue mode (contract)

Status: spec only, nothing built. Branch `feat/llm-bridge-rescue`. Only `src/bots/llm_bridge` changes;
`hermes_bridge`, `calltype_bot`, the wire format and the server stay as they are.

Owner (2026-11-12): "Watchdog dobrý nápad. Pro rescue bridge mě napadá vylepšit jay bridge podobně jako
hermes o fallback modely." Choices made in the same chat: the fallback goes into `llm_bridge` as a separate
"Rescue" contact (not into `hermes_bridge`), and the rescue bot may only restart Hermes and read its logs
(command allowlist), not run anything it likes.

Why: Hermes Agent already falls back between models (`fallback_providers`), but when the Hermes process
itself hangs, nothing in Jay can reach it. A second contact, answered by the owner's Claude Code CLI and,
when Claude is down or out of quota, by the Codex CLI, can look at Hermes' logs and restart it. A
watchdog without an LLM (outside this repo, see `C:\GIT\brain\ops\hermes-resilience.md`) handles the
common case; the rescue bot handles what a plain restart does not.

## Decisions

| # | Topic | Decision |
|---|---|---|
| F1 | Setting | `LLM_FALLBACK`: comma-separated provider ids, tried in order after `LLM_PROVIDER`, e.g. `LLM_PROVIDER=claude-cli`, `LLM_FALLBACK=codex-cli`. Same ids as `LLM_PROVIDER`. Unset or empty = today's behaviour, no wrapper. |
| F2 | Validation | Exit 78 (`ConfigException`) on an unknown id, a duplicate, or the primary provider repeated in the list. Each fallback needs its own settings exactly as if it were `LLM_PROVIDER` (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`/`OPENAI_BASE_URL`, `CLAUDE_BIN`, `CODEX_BIN`); a missing one fails at start, never at the first failover. |
| F3 | Models | `LLM_MODEL` and `LLM_EFFORT` apply to the primary only; fallbacks use their provider default (model ids differ per vendor). An `openai` fallback with a custom `OPENAI_BASE_URL` therefore fails F2 (it needs a model): accepted, documented. |
| F4 | When to switch | On ANY error of a provider (`LlmException`, launch failure, non-zero exit, HTTP error incl. 429 and 401) **before it emitted any text**. After the first text piece no switch: the user would get two answers glued together. |
| F5 | All failed | The error of the LAST provider is reported (existing apology text in `bridge.dart`); the message names every provider that failed, e.g. `Claude Code CLI: ...; Codex CLI: ...`. `isAuth` and 429 retry in `bridge.dart` (`_answer`) see the last provider's error only. |
| F6 | Cancel / timeout | Cancelling the stream cancels the attempt in flight (CLI providers kill the process via their existing `onCancel`). `LLM_TIMEOUT_SECONDS` stays the budget of the WHOLE turn. Known ceiling: a primary that hangs without an error uses the whole budget and the fallback never runs. Per-attempt timeouts are out of scope until that bites. |
| F7 | Label and logs | `label` = labels joined by ` -> ` (`Claude Code CLI -> Codex CLI`), shown by `/help` and the start log. Every switch logs one line: `LLM: <label> failed (<reason>), trying <next label>.` Nothing extra goes to the chat. |
| F8 | Group replies | `GROUP_REPLIES` defaults to `owners` when ANY provider in the chain is a CLI one (subscription terms, see README), not only when the primary is. |
| F9 | Images | Each provider receives the turn as it does today; a provider that cannot take images fails and the next one is tried. No special handling. |
| R1 | Rescue setting | `LLM_CLI_ALLOW`: `;`-separated shell commands the CLI may run, e.g. `systemctl --user restart hermes-gateway;systemctl --user status hermes-gateway --no-pager;journalctl --user -u hermes-gateway -n 200 --no-pager`. Unset = today: no tools for Claude, read-only sandbox for Codex. Logged at start (the commands, no secrets in them by contract). |
| R2 | Claude Code | With `LLM_CLI_ALLOW` the argv replaces `--tools ""` by `--tools Bash --permission-mode dontAsk --allowedTools "Bash(<cmd1>)" "Bash(<cmd2>)" ...` (exact commands, no wildcards added by the bridge). `dontAsk` denies every call no rule approves; chained commands (`&&`, `;`, `\|`) must match a rule per part, so they cannot ride on an allowed one (code.claude.com/docs/en/permissions, permission-modes, read 2026-11-12). All other flags stay (`--no-session-persistence`, `--disable-slash-commands`, own system prompt file). |
| R3 | Codex | With `LLM_CLI_ALLOW` the argv uses `--sandbox workspace-write` instead of `read-only`. The allowlist itself lives in the operator's `~/.codex/rules/default.rules` as `prefix_rule(pattern=[...], decision="allow")` lines (learn.chatgpt.com/docs/agent-configuration/rules, experimental). The bridge does not write that file; README gives the exact lines and the check `codex execpolicy check --pretty --rules ~/.codex/rules/default.rules -- <cmd>`. OPEN: the docs do not say what `codex exec` does with a command no rule matches; must be verified on the host (acceptance A6) before Codex counts as a rescue fallback. |
| R4 | Where it runs | The rescue bot runs as its own systemd user unit on the Hermes host, NOT inside the bubblewrap sandbox of `infra/bots/jay-new-bot.sh` (that sandbox hides systemd and D-Bus, restart would fail). README documents a sample unit. `ALLOWED_HANDLES` = the owner only. |
| R5 | System prompt | No built-in rescue prompt; README gives a sample `LLM_SYSTEM_PROMPT` ("You are the rescue agent of Hermes on this machine. You may only run the allowed commands. Check status and logs first, restart only when Hermes does not answer, report in Czech what you found and did."). |

## Code map

- `lib/src/config.dart`: the per-provider `switch` in `fromEnvironment` becomes a helper used for the primary
  and every fallback; `LlmConfig` gets the fallback settings list and `cliAllow`.
- `lib/src/fallback.dart` (new): `FallbackProvider implements LlmProvider` (F4-F7).
- `lib/src/factory.dart`: `buildProvider` wraps the chain when fallbacks are set.
- `lib/src/cli_providers.dart`: `arguments()` of both CLIs honour `cliAllow` (R2, R3); unchanged without it.
- `README.md`: config table rows for `LLM_FALLBACK`, `LLM_CLI_ALLOW`; section "Rescue bot" (R3 rules, R4 unit,
  R5 prompt, security note).

## Tests (`dart test` in `src/bots/llm_bridge`)

- `config_test`: F1 parse; F2 unknown, duplicate, primary repeated, missing key of a fallback; F3 model only on
  primary; F8 default; R1 parse and empty.
- `fallback_test` (new, fake providers): error before text switches; error after text does not; all fail ->
  last error with every label (F5); cancel stops the running attempt and starts no other (F6); label (F7);
  without fallbacks `buildProvider` returns the plain provider.
- `cli_providers_test`: argv of both CLIs without `cliAllow` unchanged (regression) and with it (R2, R3),
  using the existing fake-executable pattern.

## Acceptance (manual, on the owner's machine and a Hermes host)

| # | Check | Expected |
|---|---|---|
| A1 | `LLM_PROVIDER=claude-cli`, `CLAUDE_BIN=/nonexistent`, `LLM_FALLBACK=codex-cli`, message "ahoj" | Codex answers; log shows the switch line. |
| A2 | Both CLIs broken | One apology naming both failures; ❌ reaction. |
| A3 | No `LLM_FALLBACK`, no `LLM_CLI_ALLOW` | Behaviour and argv identical to master. |
| A4 | Rescue bot, "restartuj Hermes" | Claude runs only the allowed restart, reports the result. |
| A5 | Rescue bot, "smaž /tmp/x" or "restart hermes && rm -rf /tmp/x" | Refused, nothing deleted. |
| A6 | Codex as rescue (Claude broken), A4 and A5 again; `codex execpolicy check` for an allowed and a non-allowed command | Allowed runs, non-allowed is refused. If Codex runs unmatched commands, R3 is reopened before use. |
