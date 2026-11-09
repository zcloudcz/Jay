# Bot setup scripts

One command that creates a Jay bot on any computer (spec
`docs/superpowers/specs/2026-11-09-bot-factory.md`, B6). The Jay app prints it
under Settings > Bots > New bot with your handle and API already filled in.

| File | Served as | For |
| --- | --- | --- |
| `jay-new-bot.sh` | `https://jay.zcloud.cz/bots/new-bot.sh` | Linux (systemd --user), macOS (launchd), any Docker host (`--docker`) |
| `jay-new-bot.ps1` | `https://jay.zcloud.cz/bots/new-bot.ps1` | Windows (Scheduled Task at logon) |
| `test-scripts.sh` | | shellcheck, the `--dry-run` matrix, PowerShell parse + `-DryRun` matrix (CI job `bot-scripts`) |

The web app serves them through symlinks in `src/client/calltype/web/bots/`
(one source of truth; `flutter build web` copies the content, `deploy.yml`
checks it, `staticwebapp.config.json` keeps `/bots/*` out of the SPA fallback
and serves `.sh`/`.ps1` as UTF-8 text). Keep both scripts ASCII: Windows
PowerShell 5.1 reads BOM-less files as ANSI.

```bash
# Linux / macOS
curl -fsSL https://jay.zcloud.cz/bots/new-bot.sh | bash -s -- --name 'My bot' --owner CT-XXXX-XXXX --provider anthropic
# any Docker host (API providers only)
curl -fsSL https://jay.zcloud.cz/bots/new-bot.sh | bash -s -- --name 'My bot' --owner CT-XXXX-XXXX --provider openai --docker
```

```powershell
# Windows PowerShell
& ([scriptblock]::Create((irm https://jay.zcloud.cz/bots/new-bot.ps1))) -Name 'My bot' -Owner CT-XXXX-XXXX -Provider anthropic
```

What it sets up (per bot, `~/.jay-bots/<name>/`, Windows
`%USERPROFILE%\.jay-bots\<name>\`):

- `app/`: the `llm_bridge` (or `hermes_bridge` for `--provider hermes`) bundle
  from the rolling release `llm-bridge-latest` (`llm-bridge-release.yml`),
  checked against `SHA256SUMS` before anything running is touched.
- `bot.env` (600) / `bot.env.json` (ACL: you only): settings and secrets. The
  store key is generated once and never printed; the API key comes from the
  environment (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `HERMES_API_KEY`) or a
  hidden prompt, never from an argument.
- `data/`: the bot identity, sessions and encrypted chat history. Rerunning
  the same command updates the binary and settings and keeps this, so the
  handle and the contacts stay. `--remove` stops the service and asks before
  deleting it (`--yes` deletes without asking).
- `run.sh` / `run.ps1`: loads the settings and starts the bridge; logs go to
  `bot.log` (Windows: `bot.log` + `bot.err.log`). Exit code 78 (bad settings)
  is not restarted.

- Linux only, `sandbox.sh` (spec `2026-11-09-bot-access` A7): `run.sh` starts the
  bridge through bubblewrap (`bwrap`). The bot sees an EMPTY home folder; only its
  own folder (read-write), the system (read-only), the provider CLI and its login
  (`~/.claude` + `~/.claude.json`, or `~/.codex`) are visible, `/run/user/<uid>`
  and `/tmp` are private. Check it: `~/.jay-bots/<name>/sandbox.sh /bin/sh -c 'ls -a ~'`.
  WHY not systemd's `TemporaryFileSystem=`/`BindPaths=`: Ubuntu's default AppArmor
  rule against unprivileged user namespaces blocks mounts in user units
  (`226/NAMESPACE`, or the option is silently ignored); Ubuntu ships an AppArmor
  profile for bwrap. The unit itself adds `NoNewPrivileges=yes`. Without `bwrap`
  the bot runs unsandboxed and the script says so.
- macOS and Windows have no sandbox in this setup. With a CLI provider and
  `--group-replies members` the scripts print a warning: run such a bot under a
  separate OS user (its own home with only the CLI login), or keep
  `--group-replies owners` (the CLI default). Docker mode is isolated anyway.

Who can reach a bot: its owners; members of a group that has an owner in it,
when they mention the bot (`--group-replies members`, default for API keys;
their questions are paid from the owner's key or plan); other bots only in
groups whose "Bot conversation" setting allows it. The server enforces the
owner rules too (the bot publishes its policy at start).

Options: `--model`, `--prompt`, `--base-url` (any OpenAI-compatible endpoint),
`--group-replies members|owners`,
`--hermes-url`, `--api` (another Jay server), `--dry-run`. `claude-cli` and
`codex-cli` use your own installed and signed-in CLI (personal use, see
`src/bots/llm_bridge/README.md` for the vendor terms); they cannot run in
Docker. Test hooks: `JAY_BOT_BUNDLE_BASE` (another bundle location, e.g.
`file:///path`), `JAY_BOTS_DIR`, `--os` / `--arch` (dry-run matrix).
