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
