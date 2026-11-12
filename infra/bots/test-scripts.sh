#!/usr/bin/env bash
# Checks the bot setup scripts without installing anything (spec B6 tests):
#   1. shellcheck jay-new-bot.sh
#   2. --dry-run for every provider x {linux, macos, docker}: exit codes,
#      the planned actions, and that no secret is ever printed; a fake
#      npm-style CLI (#!/usr/bin/env node, node in a non-standard dir) puts
#      the node dir on the service PATH, and a missing or unstartable
#      interpreter stops the install with a clear message; on Linux the
#      start check runs inside the bubblewrap sandbox (real run when bwrap
#      works here) and must not see the rest of the home folder
#   3. PowerShell: parse jay-new-bot.ps1 (PSScriptAnalyzer when installed)
#      and the same dry-run matrix through -DryRun
#   4. (both) actions and the Hermes rescue presets per OS, and where the
#      sandbox sits with actions (spec 2026-11-12 A5, A6)
#   5. (both) --fallback / -Fallback: the provider chain, a key or CLI check
#      per fallback, and (real bubblewrap) a fake two-CLI bot whose claude
#      and codex both start in the sandbox (spec 2026-11-12 F12)
# Needs bash, shellcheck and (for 3) pwsh; set SKIP_PWSH=1 to skip 3.
# Run from anywhere: infra/bots/test-scripts.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
sh_script="$here/jay-new-bot.sh"
ps_script="$here/jay-new-bot.ps1"
fails=0 checks=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ok() { checks=$((checks + 1)); }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL: %s\n' "$*" >&2; }

echo "== shellcheck"
if shellcheck "$sh_script"; then ok; else bad "shellcheck"; fi

# Fake secrets: if any of these ever shows up in the output, it leaked.
export ANTHROPIC_API_KEY=sk-ant-test-LEAKCHECK-1
export OPENAI_API_KEY=sk-test-LEAKCHECK-2
export HERMES_API_KEY=hermes-test-LEAKCHECK-3
export JAY_BOTS_DIR="$work/bots"
name="Pepa's \"test\" bot"

expect_in() { # label output needle
  if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: expected '$3' in output"; printf '%s\n' "$2" | sed 's/^/    /' >&2; fi
}
expect_not() { # label output needle
  if grep -qF -- "$3" <<<"$2"; then bad "$1: '$3' must not appear"; else ok; fi
}

echo "== bash dry-run matrix"
for target in linux macos docker; do
  for provider in anthropic openai claude-cli codex-cli hermes; do
    label="sh $target $provider"
    args=(--dry-run --name "$name" --owner ct-aaaa-0001,CT-BBBB-0002 --provider "$provider" --api https://api.example.invalid/)
    case "$target" in
      linux) args+=(--os Linux --arch x86_64) ;;
      macos) args+=(--os Darwin --arch arm64) ;;
      docker) args+=(--docker --os Linux --arch x86_64) ;;
    esac
    set +e
    out=$(bash "$sh_script" "${args[@]}" 2>&1)
    rc=$?
    set -e
    if [ "$target" = docker ] && { [ "$provider" = claude-cli ] || [ "$provider" = codex-cli ]; }; then
      # CLI providers need the owner's signed-in CLI on the host.
      if [ "$rc" != 0 ]; then ok; else bad "$label: must refuse --docker"; fi
      expect_in "$label" "$out" "cannot run in Docker"
      continue
    fi
    if [ "$rc" = 0 ]; then ok; else bad "$label: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; continue; fi
    expect_in "$label" "$out" "jay-bot-pepa-s-test-bot"
    expect_in "$label" "$out" "CT-AAAA-0001,CT-BBBB-0002"
    expect_in "$label" "$out" "would generate BOT_STORE_KEY"
    for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
    bridge=llm-bridge
    [ "$provider" = hermes ] && bridge=hermes-bridge
    case "$target" in
      linux)
        expect_in "$label" "$out" "jay-$bridge-linux-x64.zip"
        expect_in "$label" "$out" "systemd/user/jay-bot-pepa-s-test-bot.service"
        expect_in "$label" "$out" "systemctl --user restart jay-bot-pepa-s-test-bot.service"
        # bot-access A7: bubblewrap sandbox + NoNewPrivileges on Linux.
        expect_in "$label" "$out" "sandbox.sh (bubblewrap: empty home"
        expect_in "$label" "$out" "NoNewPrivileges=yes" ;;
      macos)
        expect_not "$label" "$out" "sandbox.sh"
        expect_not "$label" "$out" "WARNING"
        expect_in "$label" "$out" "jay-$bridge-macos-arm64.zip"
        expect_in "$label" "$out" "LaunchAgents/cz.zcloud.jay-bot-pepa-s-test-bot.plist"
        expect_in "$label" "$out" "launchctl bootstrap" ;;
      docker)
        expect_in "$label" "$out" "docker run -d --name jay-bot-pepa-s-test-bot"
        image=jay-llm-bridge
        [ "$provider" = hermes ] && image=jay-hermes-bridge
        expect_in "$label" "$out" "ghcr.io/zcloudcz/$image:latest" ;;
    esac
    case "$provider" in
      claude-cli|codex-cli) expect_in "$label" "$out" "personal use only" ;;
    esac
  done
done

echo "== bash isolation warnings (bot-access A7)"
for provider in claude-cli codex-cli; do
  out=$(bash "$sh_script" --dry-run --name x --owner CT-AAAA-0001 --provider "$provider" --group-replies members --os Darwin --arch arm64 2>&1)
  expect_in "macos $provider members" "$out" "WARNING: group members can make this bot run your"
  expect_in "macos $provider members" "$out" "separate macOS user"
  out=$(bash "$sh_script" --dry-run --name x --owner CT-AAAA-0001 --provider "$provider" --group-replies members --os Linux --arch x64 2>&1)
  expect_not "linux $provider members" "$out" "WARNING"
  expect_in "linux $provider members" "$out" "Isolation: the bot runs in a bubblewrap sandbox"
done
out=$(bash "$sh_script" --dry-run --name x --owner CT-AAAA-0001 --provider anthropic --group-replies members --os Darwin --arch arm64 2>&1)
expect_not "macos anthropic members" "$out" "WARNING"

echo "== bash actions and Hermes rescue presets (spec 2026-11-12 A5, A6)"
uid=$(id -u)
out=$(bash "$sh_script" --dry-run --name rescue --owner CT-AAAA-0001 --provider claude-cli --rescue-hermes hermes-gateway --os Linux --arch x64 2>&1)
label="sh linux rescue claude-cli"
expect_in "$label" "$out" "Actions (run by the bot for its owners in 1:1 chats only): status=systemctl --user status hermes-gateway --no-pager; restart=systemctl --user restart hermes-gateway; logs=journalctl --user -u hermes-gateway -n 200 --no-pager"
# A6: only the CLI is sandboxed; the bridge must reach systemd.
expect_in "$label" "$out" "Isolation: claude runs in a bubblewrap sandbox"
expect_in "$label" "$out" "run.sh starts the bot outside the sandbox"
expect_in "$label" "$out" "would write $JAY_BOTS_DIR/rescue/cli-claude.sh as CLAUDE_BIN: exec '$JAY_BOTS_DIR/rescue/sandbox.sh' '/usr/local/bin/claude' \"\$@\""
expect_in "$label" "$out" "sandbox.sh (bubblewrap: empty home"
out=$(bash "$sh_script" --dry-run --name rescue --owner CT-AAAA-0001 --provider codex-cli --rescue-hermes ai.hermes.gateway --log-file /Users/m/.hermes/logs/gateway.log --os Darwin --arch arm64 2>&1)
label="sh macos rescue codex-cli"
expect_in "$label" "$out" "status=launchctl print gui/$uid/ai.hermes.gateway; restart=launchctl kickstart -k gui/$uid/ai.hermes.gateway; logs=tail -n 200 '/Users/m/.hermes/logs/gateway.log'"
expect_not "$label" "$out" "cli.sh"
expect_not "$label" "$out" "sandbox.sh"
out=$(bash "$sh_script" --dry-run --name rescue --owner CT-AAAA-0001 --provider claude-cli --rescue-hermes ai.hermes.gateway --os Darwin --arch arm64 2>&1)
expect_in "sh macos rescue no log" "$out" "add --log-file"
expect_not "sh macos rescue no log" "$out" "logs="
# Extra actions are appended to the preset; an API provider has no CLI to sandbox.
out=$(bash "$sh_script" --dry-run --name rescue --owner CT-AAAA-0001 --provider anthropic --rescue-hermes hermes-gateway --actions 'restart-bridge=systemctl --user restart jay-bridge' --os Linux --arch x64 2>&1)
label="sh linux rescue anthropic + actions"
expect_in "$label" "$out" "logs=journalctl --user -u hermes-gateway -n 200 --no-pager; restart-bridge=systemctl --user restart jay-bridge"
expect_in "$label" "$out" "Isolation: none needed for anthropic"
expect_not "$label" "$out" "sandbox.sh"
expect_not "$label" "$out" "cli.sh"
for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
# Without actions nothing changes: the whole bot stays in the sandbox.
out=$(bash "$sh_script" --dry-run --name plain --owner CT-AAAA-0001 --provider claude-cli --os Linux --arch x64 2>&1)
expect_not "sh linux no actions" "$out" "Actions"
expect_not "sh linux no actions" "$out" "cli.sh"
expect_in "sh linux no actions" "$out" "Isolation: the bot runs in a bubblewrap sandbox"
# A rerun keeps the actions; 'none' removes them.
mkdir -p "$JAY_BOTS_DIR/keepact"
printf "BOT_STORE_KEY='%s'\nLLM_ACTIONS='status=echo kept'\n" "AAAA" > "$JAY_BOTS_DIR/keepact/bot.env"
out=$(bash "$sh_script" --dry-run --name keepact --owner CT-AAAA-0001 --os Linux --arch x64 2>&1)
expect_in "rerun keeps actions" "$out" "1:1 chats only): status=echo kept"
out=$(bash "$sh_script" --dry-run --name keepact --owner CT-AAAA-0001 --actions none --os Linux --arch x64 2>&1)
expect_not "--actions none" "$out" "Actions ("

echo "== bash --fallback (spec 2026-11-12 F12)"
out=$(bash "$sh_script" --dry-run --name fb --owner CT-AAAA-0001 --provider claude-cli --fallback codex-cli --os Linux --arch x64 2>&1)
label="sh linux claude-cli + codex-cli"
expect_in "$label" "$out" "Provider chain: claude-cli -> codex-cli (the next one answers"
expect_in "$label" "$out" "(claude-cli -> codex-cli, systemd)"
expect_in "$label" "$out" "would check that claude starts the way the service starts it in the bubblewrap sandbox: env -i HOME=$HOME PATH=/usr/local/bin:/usr/bin:/bin $JAY_BOTS_DIR/fb/sandbox.sh /usr/local/bin/claude --version"
expect_in "$label" "$out" "would check that codex starts the way the service starts it in the bubblewrap sandbox: env -i HOME=$HOME PATH=/usr/local/bin:/usr/bin:/bin $JAY_BOTS_DIR/fb/sandbox.sh /usr/local/bin/codex --version"
expect_in "$label" "$out" "Using your own codex at /usr/local/bin/codex"
expect_in "$label" "$out" "only $JAY_BOTS_DIR/fb read-write, claude and codex read-only with their logins)"
expect_in "$label" "$out" "Isolation: the bot runs in a bubblewrap sandbox"
expect_not "$label" "$out" "cli-"
# With actions every CLI of the chain gets its own wrapper (A6 + F12).
out=$(bash "$sh_script" --dry-run --name fb --owner CT-AAAA-0001 --provider claude-cli --fallback codex-cli --rescue-hermes hermes-gateway --os Linux --arch x64 2>&1)
label="sh linux rescue claude-cli + codex-cli"
expect_in "$label" "$out" "would write $JAY_BOTS_DIR/fb/cli-claude.sh as CLAUDE_BIN: exec '$JAY_BOTS_DIR/fb/sandbox.sh' '/usr/local/bin/claude' \"\$@\""
expect_in "$label" "$out" "would write $JAY_BOTS_DIR/fb/cli-codex.sh as CODEX_BIN: exec '$JAY_BOTS_DIR/fb/sandbox.sh' '/usr/local/bin/codex' \"\$@\""
expect_in "$label" "$out" "Isolation: claude and codex run in a bubblewrap sandbox"
# An API fallback: its key is asked for like the primary's, never printed.
out=$(env -u OPENAI_API_KEY bash "$sh_script" --dry-run --name fb --owner CT-AAAA-0001 --provider anthropic --fallback ' OpenAI ' --os Linux --arch x64 2>&1)
label="sh anthropic + openai"
expect_in "$label" "$out" "Provider chain: anthropic -> openai"
expect_in "$label" "$out" "would ask for OPENAI_API_KEY for --fallback openai with a hidden prompt"
expect_not "$label" "$out" "would ask for ANTHROPIC_API_KEY"
for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
out=$(bash "$sh_script" --dry-run --name fb --owner CT-AAAA-0001 --provider openai --fallback anthropic,codex-cli --os Darwin --arch arm64 2>&1)
label="sh macos openai + anthropic + codex-cli"
expect_in "$label" "$out" "Provider chain: openai -> anthropic -> codex-cli"
expect_not "$label" "$out" "would ask for"
expect_in "$label" "$out" "would check that codex starts the way the service starts it: env -i"
for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
# F8: a CLI anywhere in the chain makes owners the default (no warning);
# members on macOS (no sandbox) warns about the fallback CLI.
expect_not "$label" "$out" "WARNING"
out=$(bash "$sh_script" --dry-run --name fb --owner CT-AAAA-0001 --provider anthropic --fallback codex-cli --group-replies members --os Darwin --arch arm64 2>&1)
expect_in "sh macos anthropic + codex-cli members" "$out" "WARNING: group members can make this bot run your codex"
# Docker: an API fallback is fine, a CLI fallback is not.
out=$(bash "$sh_script" --dry-run --name fb --owner CT-AAAA-0001 --provider anthropic --fallback openai --docker --os Linux --arch x64 2>&1)
expect_in "sh docker anthropic + openai" "$out" "Provider chain: anthropic -> openai"
expect_in "sh docker anthropic + openai" "$out" "docker run -d --name jay-bot-fb"
# A rerun keeps the stored chain; 'none' removes it.
mkdir -p "$JAY_BOTS_DIR/keepfb"
printf "BOT_STORE_KEY='%s'\nLLM_FALLBACK='codex-cli'\n" "AAAA" > "$JAY_BOTS_DIR/keepfb/bot.env"
out=$(bash "$sh_script" --dry-run --name keepfb --owner CT-AAAA-0001 --os Linux --arch x64 2>&1)
expect_in "rerun keeps fallback" "$out" "Provider chain: anthropic -> codex-cli"
expect_in "rerun keeps fallback" "$out" "would check that codex starts"
out=$(bash "$sh_script" --dry-run --name keepfb --owner CT-AAAA-0001 --fallback none --os Linux --arch x64 2>&1)
expect_not "--fallback none" "$out" "Provider chain"
expect_not "--fallback none" "$out" "codex"

echo "== bash argument errors"
check_error() { # label needle args...
  local label=$1 needle=$2; shift 2
  set +e; out=$(bash "$sh_script" --dry-run "$@" 2>&1); rc=$?; set -e
  if [ "$rc" != 0 ]; then ok; else bad "$label: must fail"; fi
  expect_in "$label" "$out" "$needle"
}
check_error "no name" "--name is required" --owner CT-AAAA-0001
check_error "no owner" "--owner is required" --name x
check_error "bad owner" "is not a Jay handle" --name x --owner martin
check_error "bad provider" "--provider must be" --name x --owner CT-AAAA-0001 --provider gemini
check_error "http api" "--api must be an https" --name x --owner CT-AAAA-0001 --api http://example.com
check_error "symbol name" "at least one letter" --name '!!!' --owner CT-AAAA-0001
check_error "intel mac" "Intel Macs" --name x --owner CT-AAAA-0001 --os Darwin --arch x86_64
check_error "base url w/o model" "--model is required" --name x --owner CT-AAAA-0001 --provider openai --base-url http://localhost:11434/v1 --os Linux --arch x64
check_error "key as argument" "unknown argument" --name x --owner CT-AAAA-0001 --api-key sk-x
check_error "bad group replies" "--group-replies must be" --name x --owner CT-AAAA-0001 --group-replies all
check_error "group replies hermes" "not for --provider hermes" --name x --owner CT-AAAA-0001 --provider hermes --group-replies members

check_error "rescue + docker" "drop --docker" --name x --owner CT-AAAA-0001 --rescue-hermes hermes-gateway --docker --os Linux --arch x64
check_error "actions + hermes" "not for --provider hermes" --name x --owner CT-AAAA-0001 --provider hermes --actions 'a=b'
check_error "rescue + members" "answers owners only" --name x --owner CT-AAAA-0001 --rescue-hermes h --group-replies members
check_error "rescue bad name" "is not a systemd unit or launchd label" --name x --owner CT-AAAA-0001 --rescue-hermes 'h; rm -rf /'
check_error "log file w/o rescue" "--log-file is only for --rescue-hermes" --name x --owner CT-AAAA-0001 --log-file /tmp/x.log
check_error "relative log file" "absolute path" --name x --owner CT-AAAA-0001 --rescue-hermes h --log-file x.log
check_error "fallback unknown" "--fallback: 'gemini' is unknown" --name x --owner CT-AAAA-0001 --fallback gemini --os Linux --arch x64
check_error "fallback hermes id" "--fallback: 'hermes' is unknown" --name x --owner CT-AAAA-0001 --fallback hermes --os Linux --arch x64
check_error "fallback twice" "--fallback: openai is listed twice" --name x --owner CT-AAAA-0001 --fallback openai,openai --os Linux --arch x64
check_error "fallback = primary" "--fallback: claude-cli is already --provider" --name x --owner CT-AAAA-0001 --provider claude-cli --fallback codex-cli,claude-cli --os Linux --arch x64
check_error "fallback + hermes" "--fallback is not for --provider hermes" --name x --owner CT-AAAA-0001 --provider hermes --fallback anthropic
check_error "cli fallback + docker" "--fallback codex-cli needs your signed-in CLI" --name x --owner CT-AAAA-0001 --fallback codex-cli --docker --os Linux --arch x64
check_error "check-only w/o cli" "--check-only is for claude-cli or codex-cli" --name x --owner CT-AAAA-0001 --fallback openai --check-only --os Linux --arch x64
mkdir -p "$JAY_BOTS_DIR/badfb"
printf "BOT_STORE_KEY='%s'\nLLM_FALLBACK='codex-cli'\n" "AAAA" > "$JAY_BOTS_DIR/badfb/bot.env"
check_error "stored fallback = new primary" "(stored in $JAY_BOTS_DIR/badfb/bot.env" --name badfb --owner CT-AAAA-0001 --provider codex-cli --os Linux --arch x64
set +e; out=$(CODEX_BIN=/nonexistent/codex bash "$sh_script" --dry-run --name x --owner CT-AAAA-0001 --provider claude-cli --fallback codex-cli --os Linux --arch x64 2>&1); rc=$?; set -e
if [ "$rc" != 0 ]; then ok; else bad "missing fallback cli: must fail"; fi
expect_in "missing fallback cli" "$out" "CODEX_BIN=/nonexistent/codex is not an executable file (needed by --fallback codex-cli)"

echo "== bash --remove dry-run"
out=$(bash "$sh_script" --dry-run --remove --name "$name" --os Linux --arch x64 2>&1)
expect_in "remove" "$out" "systemctl --user disable --now jay-bot-pepa-s-test-bot.service"
expect_in "remove" "$out" "would ask before deleting the identity"
out=$(bash "$sh_script" --dry-run --remove --yes --name "$name" --os Darwin --arch arm64 2>&1)
expect_in "remove --yes" "$out" "rm -rf"
expect_in "remove --yes" "$out" "launchctl bootout"

echo "== bash rerun keeps the identity (dry-run reads the old settings)"
mkdir -p "$JAY_BOTS_DIR/keep"
printf "BOT_STORE_KEY='%s'\nLLM_MODEL='old-model'\n" "AAAA" > "$JAY_BOTS_DIR/keep/bot.env"
out=$(bash "$sh_script" --dry-run --name keep --owner CT-AAAA-0001 --os Linux --arch x64 2>&1)
expect_in "rerun" "$out" "keeps the existing BOT_STORE_KEY"
expect_not "rerun" "$out" "would generate BOT_STORE_KEY"

echo "== bash CLI interpreter on the service PATH (npm-style script CLI)"
# An npm CLI is `#!/usr/bin/env node`; node lives in a non-standard dir
# (nvm, a tarball). The service PATH must include that dir, or the bot
# fails with exit 127 on every message.
fk="$work/fake-cli"
mkdir -p "$fk/node-v99/bin" "$fk/npm/bin" "$fk/npm/lib/codex/bin" "$fk/asdf/bin" "$fk/shim/bin"
printf '#!/bin/sh\necho v99.0.0-fake\n' > "$fk/node-v99/bin/node"
printf '#!/usr/bin/env node\nconsole.log("codex-cli 0.0.0-fake")\n' > "$fk/npm/lib/codex/bin/codex.js"
ln -s ../lib/codex/bin/codex.js "$fk/npm/bin/codex"
# A CLI whose interpreter exists nowhere.
printf '#!/usr/bin/env -S jay-test-missing-node --no-warnings\n' > "$fk/npm/bin/codex-missing"
# An asdf-style node shim: found on the user's PATH, but it needs a helper
# that the service PATH does not have, so only the start check catches it.
printf '#!/usr/bin/env jay-test-asdf\n' > "$fk/shim/bin/node"
printf '#!/bin/sh\necho asdf\n' > "$fk/asdf/bin/jay-test-asdf"
chmod +x "$fk/node-v99/bin/node" "$fk/npm/lib/codex/bin/codex.js" "$fk/npm/bin/codex-missing" "$fk/shim/bin/node" "$fk/asdf/bin/jay-test-asdf"
svc="PATH=$fk/node-v99/bin:$fk/npm/bin:/usr/local/bin:/usr/bin:/bin"
for target in linux macos; do
  label="sh $target codex-cli npm"
  case "$target" in linux) plat=(--os Linux --arch x64) ;; macos) plat=(--os Darwin --arch arm64) ;; esac
  set +e
  out=$(PATH="$fk/node-v99/bin:$PATH" CODEX_BIN="$fk/npm/bin/codex" bash "$sh_script" --dry-run --name npm --owner CT-AAAA-0001 --provider codex-cli "${plat[@]}" 2>&1)
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then ok; else bad "$label: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; continue; fi
  expect_in "$label" "$out" "service $svc (includes the dir of node"
  case "$target" in
    linux)
      expect_in "$label" "$out" "run.sh (loads the settings, starts app/bin/llm_bridge, logs to $JAY_BOTS_DIR/npm/bot.log, $svc)"
      # One interpreter detection feeds both the PATH and the sandbox: the
      # check runs the CLI inside the sandbox with the service PATH.
      expect_in "$label" "$out" "would check that codex starts the way the service starts it in the bubblewrap sandbox: env -i HOME=$HOME $svc $JAY_BOTS_DIR/npm/sandbox.sh $fk/npm/bin/codex --version"
      expect_in "$label" "$out" "sandbox.sh (bubblewrap: empty home, only $JAY_BOTS_DIR/npm read-write, codex read-only and its login, node read-only)" ;;
    macos)
      expect_in "$label" "$out" "would check that codex starts the way the service starts it: env -i HOME=$HOME $svc $fk/npm/bin/codex --version"
      expect_not "$label" "$out" "sandbox.sh"
      expect_in "$label" "$out" "cz.zcloud.jay-bot-npm.plist (RunAtLoad, KeepAlive on failure, $svc)" ;;
  esac
done
# The real start check (--check-only changes nothing) with that PATH.
set +e
out=$(env -i HOME="$work" PATH="$fk/node-v99/bin:/usr/bin:/bin" CODEX_BIN="$fk/npm/bin/codex" JAY_BOTS_DIR="$JAY_BOTS_DIR" \
  bash "$sh_script" --check-only --name npm --owner CT-AAAA-0001 --provider codex-cli --os Linux --arch x64 2>&1)
rc=$?
set -e
if [ "$rc" = 0 ]; then ok; else bad "check-only npm: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
expect_in "check-only npm" "$out" "Checked: codex starts with the bot service PATH ($fk/node-v99/bin:$fk/npm/bin:"
expect_not "check-only npm" "$out" "would download"
# Interpreter missing on the installing user's PATH: die before anything.
set +e
out=$(CODEX_BIN="$fk/npm/bin/codex-missing" bash "$sh_script" --dry-run --name npm --owner CT-AAAA-0001 --provider codex-cli --os Linux --arch x64 2>&1)
rc=$?
set -e
if [ "$rc" != 0 ]; then ok; else bad "missing interpreter: must fail"; fi
expect_in "missing interpreter" "$out" "is a script that runs 'jay-test-missing-node'"
expect_in "missing interpreter" "$out" "is not on your PATH"
expect_not "missing interpreter" "$out" "would download"
# Interpreter found, but it cannot start with the service PATH.
set +e
out=$(env -i HOME="$work" PATH="$fk/shim/bin:$fk/asdf/bin:/usr/bin:/bin" CODEX_BIN="$fk/npm/bin/codex" JAY_BOTS_DIR="$JAY_BOTS_DIR" \
  bash "$sh_script" --name npm --owner CT-AAAA-0001 --provider codex-cli --os Linux --arch x64 2>&1)
rc=$?
set -e
if [ "$rc" != 0 ]; then ok; else bad "start check: must fail"; fi
expect_in "start check" "$out" "node (or something it needs) is not found in the bot service PATH ($fk/shim/bin:$fk/npm/bin:/usr/local/bin:/usr/bin:/bin)"
expect_in "start check" "$out" "exit 127"
expect_not "start check" "$out" "Downloading"
if [ -e "$JAY_BOTS_DIR/npm" ]; then bad "start check: wrote $JAY_BOTS_DIR/npm"; else ok; fi

echo "== bash start check inside the bubblewrap sandbox (bot-access A7 + B6b)"
# The install-time check runs the CLI the way the service will: inside the
# sandbox, with the service PATH. node lives in the home folder (like
# ~/.hermes/tools/node-*): the sandbox must still find it, but neither the
# rest of the home folder nor the folders around node may be visible.
if command -v bwrap > /dev/null 2>&1 && bwrap --ro-bind / / --unshare-user --die-with-parent true > /dev/null 2>&1; then
  mkdir -p "$fk/hidden/node-sbx/bin"
  printf 'top secret\n' > "$work/secret.txt"
  # shellcheck disable=SC2016 # expanded by the fake node, inside the sandbox
  printf '#!/bin/sh\nfor p in "$HOME/secret.txt" "%s"; do if [ -e "$p" ]; then echo "VISIBLE $p"; exit 3; fi; done\necho v99.0.0-sandboxed\n' "$fk/hidden" > "$fk/hidden/node-sbx/bin/node"
  chmod +x "$fk/hidden/node-sbx/bin/node"
  set +e
  out=$(env -i HOME="$work" PATH="$fk/hidden/node-sbx/bin:/usr/bin:/bin" CODEX_BIN="$fk/npm/bin/codex" JAY_BOTS_DIR="$JAY_BOTS_DIR" \
    bash "$sh_script" --check-only --name npm --owner CT-AAAA-0001 --provider codex-cli --os Linux --arch x64 2>&1)
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then ok; else bad "sandboxed check: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
  expect_in "sandboxed check" "$out" "Checked: codex starts with the bot service PATH ($fk/hidden/node-sbx/bin:$fk/npm/bin:/usr/local/bin:/usr/bin:/bin) in the bubblewrap sandbox."
  expect_not "sandboxed check" "$out" "VISIBLE"
  # The same interpreter outside the sandbox sees the files: the test is real.
  if HOME="$work" "$fk/hidden/node-sbx/bin/node" > /dev/null 2>&1; then bad "sandboxed check: fake node must see the files outside the sandbox"; else ok; fi
  if [ -e "$JAY_BOTS_DIR/npm" ]; then bad "sandboxed check: wrote $JAY_BOTS_DIR/npm"; else ok; fi

  echo "== bash two CLIs in one sandbox: claude + --fallback codex-cli (spec 2026-11-12 F12)"
  # Fake claude (Claude Code layout under ~/.local) and fake codex (npm
  # layout), both `#!/usr/bin/env node`; node lives in a hidden folder of the
  # home and runs the script with sh. Each CLI fails when it can see the
  # rest of the home (a secret, a ~/.hermes-like folder, node's real folder)
  # or when its own login is missing.
  two="$work/two"
  mkdir -p "$work/hidden/node-two/bin" "$work/.local/share/claude/versions/9.9.9" "$work/.local/bin" \
    "$work/npm2/lib/node_modules/@openai/codex/bin" "$work/npm2/bin" "$work/.hermes" "$work/.claude" "$work/.codex" "$two/sys"
  printf 'token\n' > "$work/.hermes/.env"
  printf '{}\n' > "$work/.claude.json"
  printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$work/hidden/node-two/bin/node"
  # shellcheck disable=SC2016 # expanded by the fake CLI, inside the sandbox
  for c in claude codex; do
    login='"$HOME/.claude" "$HOME/.claude.json"'
    [ "$c" = codex ] && login='"$HOME/.codex"'
    printf '#!/usr/bin/env node\nfor p in "$HOME/secret.txt" "$HOME/.hermes" "$HOME/hidden"; do if [ -e "$p" ]; then echo "VISIBLE $p"; exit 3; fi; done\nfor p in %s; do if [ ! -e "$p" ]; then echo "NO LOGIN $p"; exit 4; fi; done\necho "%s 9.9.9-fake"\n' "$login" "$c" > "$two/$c"
  done
  mv "$two/claude" "$work/.local/share/claude/versions/9.9.9/claude"
  ln -s ../share/claude/versions/9.9.9/claude "$work/.local/bin/claude"
  mv "$two/codex" "$work/npm2/lib/node_modules/@openai/codex/bin/codex.js"
  ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$work/npm2/bin/codex"
  chmod +x "$work/hidden/node-two/bin/node" "$work/.local/share/claude/versions/9.9.9/claude" "$work/npm2/lib/node_modules/@openai/codex/bin/codex.js"
  two_env=(env -i HOME="$work" PATH="$two/sys:$work/hidden/node-two/bin:/usr/bin:/bin" CLAUDE_BIN="$work/.local/bin/claude"
    CODEX_BIN="$work/npm2/bin/codex" JAY_BOTS_DIR="$JAY_BOTS_DIR" JAY_BOT_BUNDLE_BASE="file://$two/bundle")
  set +e
  out=$("${two_env[@]}" bash "$sh_script" --check-only --name two --owner CT-AAAA-0001 --provider claude-cli --fallback codex-cli --os Linux --arch x64 2>&1)
  rc=$?
  set -e
  label="two-CLI check"
  if [ "$rc" = 0 ]; then ok; else bad "$label: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
  expect_in "$label" "$out" "Checked: claude starts with the bot service PATH ($work/hidden/node-two/bin:$work/.local/bin:$work/npm2/bin:/usr/local/bin:/usr/bin:/bin) in the bubblewrap sandbox."
  expect_in "$label" "$out" "Checked: codex starts with the bot service PATH"
  expect_not "$label" "$out" "VISIBLE"
  # The same CLIs outside the sandbox see the files: the test is real.
  if PATH="$work/hidden/node-two/bin:$PATH" HOME="$work" "$work/npm2/bin/codex" > /dev/null 2>&1; then bad "$label: fake codex must see the files outside the sandbox"; else ok; fi
  # A whole (fake) install, without systemd and without the network: a
  # fake bundle served from a file:// URL whose "bridge" starts both CLIs
  # the way llm_bridge does (CLAUDE_BIN, CODEX_BIN from bot.env) and logs
  # what they printed. systemctl is a fake that fails, so the script uses
  # its background mode and never touches the real user services.
  printf '#!/bin/sh\necho "systemctl $*" >> "%s/systemctl.calls"\nexit 1\n' "$two" > "$two/sys/systemctl"
  chmod +x "$two/sys/systemctl"
  mkdir -p "$two/bundle-src/bin"
  # shellcheck disable=SC2016 # expanded by the fake bridge
  printf '#!/bin/sh\nfor v in CLAUDE_BIN CODEX_BIN; do eval "b=\\${$v:-}"; if o=$("$b" --version 2>&1); then echo "0 $v ok $o"; else echo "0 $v FAILED $(printf %%s "$o" | tr "\\n" " ")"; fi; done\nif [ -e "$HOME/secret.txt" ]; then echo "0 bridge sees the home"; else echo "0 bridge in the sandbox"; fi\necho "0 Connected. CT-TEST-0001"\n' > "$two/bundle-src/bin/llm_bridge"
  mkdir -p "$two/bundle"
  for a in x64 arm64; do (cd "$two/bundle-src" && python3 -m zipfile -c "$two/bundle/jay-llm-bridge-linux-$a.zip" bin); done
  (cd "$two/bundle" && sha256sum -- *.zip > SHA256SUMS)
  for variant in plain rescue; do
    label="two-CLI install $variant"
    extra=()
    [ "$variant" = rescue ] && extra=(--actions 'status=true')
    set +e
    out=$("${two_env[@]}" bash "$sh_script" --name "two-$variant" --owner CT-AAAA-0001 --provider claude-cli --fallback codex-cli ${extra[@]+"${extra[@]}"} 2>&1)
    rc=$?
    set -e
    d="$JAY_BOTS_DIR/two-$variant"
    if [ "$rc" = 0 ]; then ok; else bad "$label: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; continue; fi
    expect_in "$label" "$out" "No user systemd here"
    expect_in "$label" "$out" "Handle: CT-TEST-0001"
    for _ in $(seq 1 20); do grep -q Connected "$d/bot.log" 2> /dev/null && break; sleep 0.5; done
    log=$(cat "$d/bot.log" 2> /dev/null || true)
    expect_in "$label" "$log" "CLAUDE_BIN ok claude 9.9.9-fake"
    expect_in "$label" "$log" "CODEX_BIN ok codex 9.9.9-fake"
    expect_not "$label" "$log" "VISIBLE"
    settings=$(cat "$d/bot.env")
    expect_in "$label" "$settings" "LLM_FALLBACK='codex-cli'"
    if [ "$variant" = rescue ]; then
      # A6: the bridge runs outside the sandbox, each CLI through its wrapper.
      expect_in "$label" "$log" "bridge sees the home"
      expect_in "$label" "$settings" "CLAUDE_BIN='$d/cli-claude.sh'"
      expect_in "$label" "$settings" "CODEX_BIN='$d/cli-codex.sh'"
      if [ -x "$d/cli-claude.sh" ] && [ -x "$d/cli-codex.sh" ]; then ok; else bad "$label: cli-claude.sh and cli-codex.sh must exist"; fi
    else
      expect_in "$label" "$log" "bridge in the sandbox"
      expect_in "$label" "$settings" "CLAUDE_BIN='$work/.local/bin/claude'"
      expect_in "$label" "$settings" "CODEX_BIN='$work/npm2/bin/codex'"
      if [ -e "$d/cli-claude.sh" ] || [ -e "$d/cli-codex.sh" ]; then bad "$label: no cli-*.sh without actions"; else ok; fi
    fi
    # Nothing else of the home is visible in the bot's sandbox.
    # shellcheck disable=SC2016 # expanded inside the sandbox
    if HOME="$work" "$d/sandbox.sh" /bin/sh -c 'ls -a "$HOME/.hermes" "$HOME/secret.txt" "$HOME/hidden"' > /dev/null 2>&1; then bad "$label: sandbox shows the home"; else ok; fi
    # shellcheck disable=SC2016 # expanded inside the sandbox
    if HOME="$work" "$d/sandbox.sh" /bin/sh -c 'test -e "$HOME/.claude" && test -e "$HOME/.codex"'; then ok; else bad "$label: sandbox must show both logins"; fi
  done
  calls=$(cat "$two/systemctl.calls" 2> /dev/null || true)
  expect_not "two-CLI install: only the detection called systemctl" "$calls" "restart"
  expect_not "two-CLI install: only the detection called systemctl" "$calls" "enable"
else
  echo "   skipped: bubblewrap is not usable on this machine"
fi

if [ "${SKIP_PWSH:-0}" = 1 ]; then
  echo "== PowerShell skipped (SKIP_PWSH=1)"
else
  echo "== PowerShell parse"
  if pwsh -NoProfile -Command "
      \$errors = \$null
      [System.Management.Automation.Language.Parser]::ParseFile('$ps_script', [ref]\$null, [ref]\$errors) | Out-Null
      if (\$errors) { \$errors | ForEach-Object { Write-Host \$_ }; exit 1 }
      if (Get-Module -ListAvailable PSScriptAnalyzer) {
        \$issues = Invoke-ScriptAnalyzer -Path '$ps_script' -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseShouldProcessForStateChangingFunctions,PSAvoidUsingConvertToSecureStringWithPlainText
        if (\$issues) { \$issues | Format-Table -AutoSize | Out-String | Write-Host; exit 1 }
        Write-Host 'PSScriptAnalyzer: no errors or warnings'
      } else { Write-Host 'PSScriptAnalyzer not installed: parse only' }
    "; then ok; else bad "PowerShell parse/analyzer"; fi

  echo "== PowerShell dry-run matrix"
  for provider in anthropic openai claude-cli codex-cli hermes; do
    label="ps1 $provider"
    set +e
    out=$(USERPROFILE="$work/profile" pwsh -NoProfile -Command "& '$ps_script' -DryRun -Name 'Pepa''s \"test\" bot' -Owner 'ct-aaaa-0001, CT-BBBB-0002' -Provider $provider -Api https://api.example.invalid/ -Arch AMD64" 2>&1)
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then ok; else bad "$label: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; continue; fi
    bridge=llm-bridge
    [ "$provider" = hermes ] && bridge=hermes-bridge
    expect_in "$label" "$out" "jay-$bridge-windows-x64.zip"
    expect_in "$label" "$out" "Scheduled Task 'Jay bot pepa-s-test-bot'"
    expect_in "$label" "$out" "CT-AAAA-0001,CT-BBBB-0002"
    for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
  done
  set +e
  out=$(USERPROFILE="$work/profile" pwsh -NoProfile -Command "& '$ps_script' -DryRun -Name x -Owner martin -Arch AMD64" 2>&1)
  rc=$?
  set -e
  if [ "$rc" != 0 ]; then ok; else bad "ps1 bad owner must fail"; fi
  expect_in "ps1 bad owner" "$out" "is not a Jay handle"
  out=$(USERPROFILE="$work/profile" pwsh -NoProfile -Command "& '$ps_script' -DryRun -Name x -Owner CT-AAAA-0001 -Provider codex-cli -GroupReplies members -Arch AMD64" 2>&1)
  expect_in "ps1 codex members" "$out" "no sandbox on Windows"
  out=$(USERPROFILE="$work/profile" pwsh -NoProfile -Command "& '$ps_script' -DryRun -Remove -Name x -Arch AMD64" 2>&1)
  expect_in "ps1 remove" "$out" "would unregister the Scheduled Task 'Jay bot x'"

  echo "== PowerShell actions and Hermes rescue presets (spec 2026-11-12 A5)"
  ps_run() { USERPROFILE="$work/profile" pwsh -NoProfile -Command "& '$ps_script' -DryRun -Owner CT-AAAA-0001 -Arch AMD64 $1" 2>&1; }
  out=$(ps_run "-Name rescue -Provider claude-cli -RescueHermes 'Hermes Gateway'")
  label="ps1 rescue task"
  expect_in "$label" "$out" "Actions (run by the bot for its owners in 1:1 chats only): status=schtasks.exe /query /tn \"Hermes Gateway\" /v /fo list; restart=powershell.exe -NoProfile -NonInteractive -Command \"schtasks.exe /end /tn 'Hermes Gateway'; schtasks.exe /run /tn 'Hermes Gateway'\""
  expect_in "$label" "$out" "group replies: owners"
  out=$(ps_run "-Name rescue -Provider codex-cli -RescueHermes hermes -RescueKind service -LogFile 'C:\\Users\\m\\.hermes\\logs\\gateway.log' -Actions 'ping=ping.exe -n 1 127.0.0.1'")
  label="ps1 rescue service"
  expect_in "$label" "$out" "status=sc.exe query \"hermes\"; restart=powershell.exe -NoProfile -NonInteractive -Command \"Restart-Service -Name 'hermes'\"; logs=powershell.exe -NoProfile -NonInteractive -Command \"Get-Content -Tail 200 -LiteralPath 'C:\\Users\\m\\.hermes\\logs\\gateway.log'\"; ping=ping.exe -n 1 127.0.0.1"
  for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
  ps_error() { # label needle args
    set +e; out=$(ps_run "$3"); rc=$?; set -e
    if [ "$rc" != 0 ]; then ok; else bad "$1: must fail"; fi
    expect_in "$1" "$out" "$2"
  }
  ps_error "ps1 rescue hermes provider" "not for -Provider hermes" "-Name x -Provider hermes -RescueHermes h"
  ps_error "ps1 rescue members" "answers owners only" "-Name x -RescueHermes h -GroupReplies members"
  ps_error "ps1 rescue bad name" "is not a Scheduled Task or service name" "-Name x -RescueHermes \"h'; x\""
  ps_error "ps1 log file w/o rescue" "-LogFile is only for -RescueHermes" "-Name x -LogFile C:\\x.log"

  echo "== PowerShell -Fallback (spec 2026-11-12 F12)"
  out=$(ps_run "-Name fb -Provider claude-cli -Fallback codex-cli")
  label="ps1 claude-cli + codex-cli"
  expect_in "$label" "$out" "Provider chain: claude-cli -> codex-cli (the next one answers"
  expect_in "$label" "$out" "(claude-cli -> codex-cli, Scheduled Task)"
  expect_in "$label" "$out" "would check that claude starts the way the bot starts it"
  expect_in "$label" "$out" "would check that codex starts the way the bot starts it"
  expect_in "$label" "$out" "Using your own codex at"
  out=$(unset OPENAI_API_KEY; ps_run "-Name fb -Provider anthropic -Fallback ' OpenAI '")
  label="ps1 anthropic + openai"
  expect_in "$label" "$out" "Provider chain: anthropic -> openai"
  expect_in "$label" "$out" "would ask for OPENAI_API_KEY for -Fallback openai with a hidden prompt"
  expect_not "$label" "$out" "would ask for ANTHROPIC_API_KEY"
  for secret in LEAKCHECK-1 LEAKCHECK-2 LEAKCHECK-3; do expect_not "$label" "$out" "$secret"; done
  ps_error "ps1 fallback unknown" "-Fallback: 'gemini' is unknown" "-Name x -Fallback gemini"
  ps_error "ps1 fallback twice" "-Fallback: codex-cli is listed twice" "-Name x -Fallback codex-cli,codex-cli"
  out=$(ps_run "-Name fb -Fallback 'openai, codex-cli'")
  expect_in "ps1 quoted list" "$out" "Provider chain: anthropic -> openai -> codex-cli"
  ps_error "ps1 fallback = primary" "-Fallback: codex-cli is already -Provider" "-Name x -Provider codex-cli -Fallback codex-cli"
  ps_error "ps1 fallback + hermes" "-Fallback is not for -Provider hermes" "-Name x -Provider hermes -Fallback anthropic"
  mkdir -p "$JAY_BOTS_DIR/keepfbps"
  printf '{"BOT_STORE_KEY":"AAAA","LLM_FALLBACK":"openai"}' > "$JAY_BOTS_DIR/keepfbps/bot.env.json"
  out=$(ps_run "-Name keepfbps")
  expect_in "ps1 rerun keeps fallback" "$out" "Provider chain: anthropic -> openai"
  out=$(ps_run "-Name keepfbps -Fallback none")
  expect_not "ps1 -Fallback none" "$out" "Provider chain"

  echo "== PowerShell CLI interpreter (npm .cmd shim needs node)"
  mkdir -p "$fk/win-npm" "$fk/win-node"
  printf '@ECHO off\r\nSET "_prog=node"\r\n"%%_prog%%" "%%dp0%%\\node_modules\\@openai\\codex\\bin\\codex.js" %%*\r\n' > "$fk/win-npm/codex.cmd"
  printf '#!/bin/sh\necho v99.0.0-fake\n' > "$fk/win-node/node"
  chmod +x "$fk/win-node/node"
  set +e
  out=$(CODEX_BIN="$fk/win-npm/codex.cmd" USERPROFILE="$work/profile" pwsh -NoProfile -Command "\$env:PATH = '$fk/win-node' + [IO.Path]::PathSeparator + \$env:PATH; & '$ps_script' -DryRun -Name npm -Owner CT-AAAA-0001 -Provider codex-cli -Arch AMD64" 2>&1)
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then ok; else bad "ps1 npm shim: exit $rc"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
  expect_in "ps1 npm shim" "$out" "service PATH=$fk/win-node:$fk/win-npm:"
  expect_in "ps1 npm shim" "$out" "includes the folder of node"
  expect_in "ps1 npm shim" "$out" "PATH starts with $fk/win-node:$fk/win-npm"
  set +e
  # Hermetic: a hosted runner has a real node on its PATH, so hide it.
  mkdir -p "$fk/empty"
  out=$(CODEX_BIN="$fk/win-npm/codex.cmd" USERPROFILE="$work/profile" pwsh -NoProfile -Command "\$env:PATH = '$fk/empty'; & '$ps_script' -DryRun -Name npm -Owner CT-AAAA-0001 -Provider codex-cli -Arch AMD64" 2>&1)
  rc=$?
  set -e
  if [ "$rc" != 0 ]; then ok; else bad "ps1 missing node: must fail"; fi
  expect_in "ps1 missing node" "$out" "runs 'node', but 'node' is not on your PATH"
fi

printf '== %d checks, %d failed\n' "$checks" "$fails"
[ "$fails" = 0 ]
