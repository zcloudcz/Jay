# llm_bridge: fallback providers and a rescue mode (contract)

Status: approved with changes (owner 2026-11-12, Discord, after review): F-part as below plus F10/F11; the R-part is REPLACED by bridge-executed named actions (A-rows). Branch `feat/llm-bridge-rescue`. Changes: `src/bots/llm_bridge`, `infra/bots/jay-new-bot.sh` + `.ps1` (+ README/acceptance); `hermes_bridge`, `calltype_bot`, the wire format and the server stay as they are.

Owner (2026-11-12): "Watchdog dobrý nápad. Pro rescue bridge mě napadá vylepšit jay bridge podobně jako
hermes o fallback modely." Choices made in the same chat: the fallback goes into `llm_bridge` as a separate
"Rescue" contact (not into `hermes_bridge`), and the rescue bot may only restart Hermes and read its logs
(command allowlist), not run anything it likes.

Why: Hermes Agent already falls back between models (`fallback_providers`), but when the Hermes process
itself hangs, nothing in Jay can reach it. A second contact, answered by the owner's Claude Code CLI and,
when Claude is down or out of quota, by the Codex CLI, can look at Hermes' logs and restart it. A
watchdog without an LLM (outside this repo, see `~/brain ops/hermes-resilience.md`) handles the
common case; the rescue bot handles what a plain restart does not.

## Decisions

| # | Topic | Decision |
|---|---|---|
| F1 | Setting | `LLM_FALLBACK`: comma-separated provider ids, tried in order after `LLM_PROVIDER`, e.g. `LLM_PROVIDER=claude-cli`, `LLM_FALLBACK=codex-cli`. Same ids as `LLM_PROVIDER`. Unset or empty = today's behaviour, no wrapper. |
| F2 | Validation | Exit 78 (`ConfigException`) on an unknown id, a duplicate, or the primary provider repeated in the list. Each fallback needs its own settings exactly as if it were `LLM_PROVIDER` (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`/`OPENAI_BASE_URL`, `CLAUDE_BIN`, `CODEX_BIN`); a missing one fails at start, never at the first failover. |
| F3 | Models | `LLM_MODEL` and `LLM_EFFORT` apply to the primary only; fallbacks use their provider default (model ids differ per vendor). An `openai` fallback with a custom `OPENAI_BASE_URL` therefore fails F2 (it needs a model): accepted, documented. |
| F4 | When to switch | On ANY error of a provider (`LlmException`, launch failure, non-zero exit, HTTP error incl. 429 and 401) **before it emitted any text**. After the first text piece no switch: the user would get two answers glued together. |
| F5 | All failed | The error of the LAST provider is reported (existing apology text in `bridge.dart`); the message names every provider that failed, e.g. `Claude Code CLI: ...; Codex CLI: ...`. `isAuth` and 429 retry in `bridge.dart` (`_answer`) see the last provider's error only. |
| F6 | Cancel / timeout | Cancelling the stream cancels the attempt in flight (CLI providers kill the process via their existing `onCancel`). `LLM_TIMEOUT_SECONDS` stays the budget of the WHOLE turn. (The original "per-attempt timeouts out of scope" note is superseded by F11.) |
| F7 | Label and logs | `label` = labels joined by ` -> ` (`Claude Code CLI -> Codex CLI`), shown by `/help` and the start log. Every switch logs one line: `LLM: <label> failed (<reason>), trying <next label>.` Nothing extra goes to the chat. |
| F8 | Group replies | `GROUP_REPLIES` defaults to `owners` when ANY provider in the chain is a CLI one (subscription terms, see README), not only when the primary is. |
| F9 | Images | Each provider receives the turn as it does today; a provider that cannot take images fails and the next one is tried. No special handling. |
| F10 | 429 with fallbacks | With at least one fallback, a 429 switches to the next provider at once; the existing single retry in `bridge.dart` `_answer` is skipped (it would restart the whole chain). Without fallbacks: today's single retry. |
| F11 | First-output timeout | Each attempt gets `LLM_FIRST_OUTPUT_SECONDS` (default 60) to emit its first text piece; on expiry the attempt is cancelled (CLI process killed) and counts as an error, so the next provider runs. The whole-turn `LLM_TIMEOUT_SECONDS` still applies. Without fallbacks the first-output timeout also applies (a hung CLI then fails after 60 s instead of 300 s); document it. Implementation: `FirstOutputGuard` wraps every provider; `0` = no guard. Note: the CLI providers emit their whole answer when the process ends, so for them this bounds the whole run (README says to raise it for slow models). |
| A1 | Named actions (replace R1-R5) | `LLM_ACTIONS`: `;`-separated `name=command line` pairs, e.g. on Linux `status=systemctl --user status hermes-gateway --no-pager; logs=journalctl --user -u hermes-gateway -n 200 --no-pager; restart=systemctl --user restart hermes-gateway; restart-bridge=systemctl --user restart jay-bridge`. Names `[a-z0-9-]{1,32}`, unique, max 20; the command line is split into argv by the bridge (simple quoting rules, documented, tested) and run WITHOUT a shell. Unset = no actions, behaviour identical to today. Logged at start (names and commands; no secrets in them by contract). |
| A2 | How the model uses them | The system prompt gets one generated block listing the action NAMES (not the commands) and the directive: a line `[action: <name>]` anywhere in the answer. The bridge strips the directives, runs each named action (unknown name -> short error line back to the model, nothing runs), captures exit code + stdout/stderr (last 8 KiB, ANSI stripped; README warns not to configure commands that print secrets), and calls the model again with the results as a user turn. Max `LLM_ACTION_STEPS` rounds (default 3) per user message, then the last answer is posted. Action timeout `LLM_ACTION_SECONDS` (default 60), process killed on expiry. The progress message shows `Running: <name>`. |
| A3 | Enforcement | Only exactly configured commands ever run; the model never passes arguments (no parameters in v1). Holds for every provider (Claude, Codex, API) because the bridge runs them. CLI providers keep NO tools (`--tools ""`, Codex `--sandbox read-only`). |
| A4 | Multi-platform | `llm_bridge` is multi-platform (bundles linux-x64/arm64, macos-arm64, windows-x64). Actions are plain configured commands: Windows starts them with `runInShell: false`; a `.cmd`/`.bat` target goes through `cmd.exe /d /c` with correct quoting (same rules as the CLI providers' `.cmd` handling); PowerShell as `powershell -NoProfile -Command ...` written by the operator. Unit tests cover argv splitting and launcher choice for Linux, macOS and Windows; the real process path runs on the CI OS. |
| A5 | Setup script presets | `jay-new-bot.sh` / `.ps1` gain `--actions '<value>'` (stored in the settings file, never on the service command line) and `--rescue-hermes <name>` that fills platform defaults: Linux systemd user unit (status/logs/restart), macOS launchd (`launchctl print gui/$UID/<label>`, `launchctl kickstart -k gui/$UID/<label>`, logs from a `--log-file` path), Windows Scheduled Task or service (`schtasks /query /tn`, `schtasks /end` + `/run`, or `sc query/stop/start`; logs from a `--log-file` path). `--rescue-hermes` also forces `GROUP_REPLIES=owners`. |
| A6 | Sandbox placement | With actions the bridge must reach the service manager, so on Linux the bubblewrap sandbox wraps only the CLI provider process (wrapper used as `CLAUDE_BIN`/`CODEX_BIN`), not the whole bridge. Without actions nothing changes. macOS/Windows: no sandbox (as today), warning stays. |
| A7 | Who may trigger | Actions run only for owners' messages in 1:1 chats; in groups and from peer bots the directive is stripped, ignored and logged. |
| A8 | Prompt | No built-in rescue persona; README gives a sample `LLM_SYSTEM_PROMPT` ("You are the rescue agent of Hermes on this machine. Check status and logs first, restart only when Hermes does not answer, report in Czech what you found and did."). |
| A9 | Codex permissions | Owner asked whether higher Codex permissions help: no. `danger-full-access` or bypassing approvals removes the sandbox but still enforces no allowlist; with A1-A3 Codex needs no permissions at all. |

## Code map

- `lib/src/config.dart`: the per-provider `switch` in `fromEnvironment` becomes a helper used for the primary
  and every fallback (`ProviderSettings`); `LlmConfig` gets `fallbacks` and `firstOutputTimeout`. (`cliAllow`
  was a leftover of the replaced R-part and is not added.)
- `lib/src/fallback.dart` (new): `FallbackProvider implements LlmProvider` (F4-F7), `FirstOutputGuard` (F11).
- `lib/src/factory.dart`: `buildProvider` wraps the chain when fallbacks are set; every attempt sits in a
  `FirstOutputGuard`. `LlmBridge.retryRateLimit` is false with fallbacks (F10).
- `lib/src/actions.dart` (new): parsing (A1), argv splitting, OS launcher (A4), runner with timeout and output cap (A2); the action loop in `bridge.dart` (A2, A7).
- `infra/bots/jay-new-bot.sh` / `.ps1`: `--actions`, `--rescue-hermes` presets (A5), sandbox placement (A6).
- `README.md`: config rows for `LLM_FALLBACK`, `LLM_FIRST_OUTPUT_SECONDS`, `LLM_ACTIONS`, `LLM_ACTION_STEPS`, `LLM_ACTION_SECONDS`; section "Rescue bot" (presets per OS, prompt, security note).

## Tests (`dart test` in `src/bots/llm_bridge`)

- `config_test`: F1 parse; F2 unknown, duplicate, primary repeated, missing key of a fallback; F3 model only on
  primary; F8 default; A1 parse and empty.
- `fallback_test` (new, fake providers): error before text switches; error after text does not; all fail ->
  last error with every label (F5); cancel stops the running attempt and starts no other (F6); label (F7);
  without fallbacks `buildProvider` returns the plain provider (inside its `FirstOutputGuard`, F11).
- `cli_providers_test`: argv of both CLIs unchanged (regression).
- `actions_test` (new): parse/validate, argv splitting incl. quotes, Windows `.cmd` launcher, timeout kill, output cap, unknown name, max steps, group/peer directives ignored (A7), a real fake-executable run.
- bridge tests: action loop with a fake provider (one action, two rounds, max steps), F10, F11.
- `infra/bots/test-scripts.sh`: `--actions` and `--rescue-hermes` dry-run per OS, sandbox placement lines.

## Acceptance (manual, on the owner's machine and a Hermes host)

| # | Check | Expected |
|---|---|---|
| AC1 | `LLM_PROVIDER=claude-cli`, `CLAUDE_BIN=/nonexistent`, `LLM_FALLBACK=codex-cli`, message "ahoj" | Codex answers; log shows the switch line. |
| AC2 | Both CLIs broken | One apology naming both failures; ❌ reaction. |
| AC3 | No `LLM_FALLBACK`, no `LLM_ACTIONS` | Behaviour and argv identical to master. |
| AC4 | Rescue bot, "restartuj Hermes" | The model asks for the restart action, the bridge runs exactly the configured command, the model reports. |
| AC5 | Rescue bot, "smaž /tmp/x" or "restart hermes && rm -rf /tmp/x" | Refused, nothing deleted. |
| AC6 | Codex as rescue (Claude broken), AC4 and AC5 again | Same results (the bridge enforces the list; Codex has no tools). |
| AC7 | Windows host, rescue preset for a Scheduled Task, "status" | The configured `schtasks /query` runs and the model reports it. |
