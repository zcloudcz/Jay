#!/usr/bin/env bash
# Jay: create, update or remove a bot on this computer with ONE command.
#
#   curl -fsSL https://jay.zcloud.cz/bots/new-bot.sh | bash -s -- \
#     --name 'My bot' --owner CT-XXXX-XXXX --provider anthropic
#
# Spec: docs/superpowers/specs/2026-11-09-bot-factory.md (B6). The Jay app
# (Settings > Bots > New bot) prints this command with your handle filled in.
#
# What it does: downloads the bot bundle (no Dart or Docker needed) to
# ~/.jay-bots/<name>/, generates the bot's store key (never printed), asks
# for the provider API key with a hidden prompt (or reads it from the
# environment; never from an argument, so it stays out of shell history),
# writes a 600 settings file, installs a user service (systemd --user on
# Linux, launchd on macOS), starts it and waits until the bot is connected.
# The bot then writes to you in Jay. Rerun with the same --name to update:
# the identity (handle, contacts) is kept. --remove stops and deletes it.
#
# The bot's private keys are created on THIS machine and never leave it; the
# Jay server never sees them. The bot runs only while this machine runs.
set -euo pipefail
umask 077

DEFAULT_API=https://calltype-beta-zahy.azurewebsites.net
BUNDLE_BASE=${JAY_BOT_BUNDLE_BASE:-https://github.com/zcloudcz/Jay/releases/download/llm-bridge-latest}
IMAGE_LLM=ghcr.io/zcloudcz/jay-llm-bridge:latest
IMAGE_HERMES=ghcr.io/zcloudcz/jay-hermes-bridge:latest
BOTS_DIR=${JAY_BOTS_DIR:-$HOME/.jay-bots}

usage() {
  cat <<'EOF'
Usage: new-bot.sh --name NAME --owner CT-XXXX-XXXX[,CT-...] [options]

  --name NAME          bot name shown in Jay (also the folder/service name)
  --owner HANDLES      your Jay handle(s); only they can talk to the bot
  --provider P         anthropic (default) | openai | claude-cli | codex-cli | hermes
  --api URL            Jay API (default https://calltype-beta-zahy.azurewebsites.net)
  --model ID           model id or CLI alias (default: provider's default)
  --prompt TEXT        system prompt (default: friendly assistant)
  --base-url URL       openai: any OpenAI-compatible endpoint (Ollama, OpenRouter, Azure)
  --hermes-url URL     hermes: Hermes API server (default http://127.0.0.1:8642)
  --fallback IDS       providers tried in order when the one before fails
                       before it sent any text (LLM_FALLBACK), comma-separated:
                       anthropic, openai, claude-cli, codex-cli; e.g.
                       --provider claude-cli --fallback codex-cli. Each gets
                       its own key or CLI check like --provider; a rerun keeps
                       them, 'none' removes them
  --group-replies M    members | owners: who besides you the bot answers in a
                       group that you are in (default: members for API keys,
                       owners for claude-cli/codex-cli)
  --actions VALUE      named commands the bot may run for you (LLM_ACTIONS):
                       'name=command; name2=command2'; 'none' removes them
  --rescue-hermes NAME make this a rescue bot for Hermes: actions status,
                       logs and restart for the systemd user unit (Linux) or
                       launchd label (macOS) NAME; forces --group-replies owners
  --log-file PATH      with --rescue-hermes: 'logs' reads this file (macOS
                       needs it; on Linux it replaces journalctl)
  --docker             run as a Docker container instead of a native service
  --remove             stop and remove the bot (asks before deleting its identity)
  --yes                with --remove: also delete the identity without asking
  --dry-run            print what would be done, change nothing
  --check-only         claude-cli/codex-cli (also as --fallback): only check that
                       every CLI starts the way the bot service starts it,
                       change nothing
  -h, --help           this help

API keys are read from ANTHROPIC_API_KEY / OPENAI_API_KEY / HERMES_API_KEY if
set, otherwise asked for with a hidden prompt. claude-cli and codex-cli use your
own signed-in Claude Code / Codex CLI (personal use, see the vendors' terms);
CLAUDE_BIN / CODEX_BIN pick a CLI other than the one on your PATH. The same
holds for the providers given with --fallback.

Who can reach the bot: you (the owners); members of a group you are in when
they mention the bot (their questions cost YOUR key or plan); other bots only
in groups whose bot conversation setting allows it. On Linux the bot runs in
a bubblewrap sandbox that sees only its own folder and the CLIs it needs.
EOF
}

die() { printf 'jay-new-bot: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

name='' owner='' provider=anthropic api=$DEFAULT_API model='' prompt=''
base_url='' hermes_url='' remove=0 dry=0 docker=0 yes=0 group_replies='' check_only=0
model_set=0 prompt_set=0 base_url_set=0 hermes_url_set=0 group_replies_set=0
actions='' actions_set=0 rescue='' log_file_arg='' fallback='' fallback_set=0
os_override='' arch_override=''

need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value (see --help)"; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) need_value "$@"; name=$2; shift 2 ;;
    --owner) need_value "$@"; owner=$2; shift 2 ;;
    --provider) need_value "$@"; provider=$2; shift 2 ;;
    --api) need_value "$@"; api=$2; shift 2 ;;
    --model) need_value "$@"; model=$2; model_set=1; shift 2 ;;
    --prompt) need_value "$@"; prompt=$2; prompt_set=1; shift 2 ;;
    --base-url) need_value "$@"; base_url=$2; base_url_set=1; shift 2 ;;
    --hermes-url) need_value "$@"; hermes_url=$2; hermes_url_set=1; shift 2 ;;
    --group-replies) need_value "$@"; group_replies=$2; group_replies_set=1; shift 2 ;;
    --actions) need_value "$@"; actions=$2; actions_set=1; shift 2 ;;
    --rescue-hermes) need_value "$@"; rescue=$2; shift 2 ;;
    --fallback) need_value "$@"; fallback=$2; fallback_set=1; shift 2 ;;
    --log-file) need_value "$@"; log_file_arg=$2; shift 2 ;;
    --docker) docker=1; shift ;;
    --remove) remove=1; shift ;;
    --yes) yes=1; shift ;;
    --dry-run) dry=1; shift ;;
    --check-only) check_only=1; shift ;;
    # Test hooks for the dry-run matrix (infra/bots/test-scripts.sh).
    --os) need_value "$@"; os_override=$2; shift 2 ;;
    --arch) need_value "$@"; arch_override=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# --- validation -------------------------------------------------------------
[ -n "$name" ] || die "--name is required"
[ "${#name}" -le 40 ] || die "--name is longer than 40 characters"
case "$name" in *[[:cntrl:]]*) die "--name must not contain control characters" ;; esac
# Folder and service name: lower-case letters, digits and dashes only, so it
# never needs quoting in a unit file, a plist or a container name. Common
# accented letters become their base letter first ("Muj bot", not "m-j-bot"),
# the same result as the PowerShell script's Unicode decomposition. The
# letters are written as UTF-8 bytes so this file stays ASCII.
ascii_name=$name
accents=($'\xc3\xa1'a $'\xc3\x81'A $'\xc4\x8d'c $'\xc4\x8c'C $'\xc4\x8f'd $'\xc4\x8e'D $'\xc3\xa9'e $'\xc3\x89'E $'\xc4\x9b'e $'\xc4\x9a'E
  $'\xc3\xad'i $'\xc3\x8d'I $'\xc5\x88'n $'\xc5\x87'N $'\xc3\xb3'o $'\xc3\x93'O $'\xc5\x99'r $'\xc5\x98'R $'\xc5\xa1's $'\xc5\xa0'S
  $'\xc5\xa5't $'\xc5\xa4'T $'\xc3\xba'u $'\xc3\x9a'U $'\xc5\xaf'u $'\xc5\xae'U $'\xc3\xbd'y $'\xc3\x9d'Y $'\xc5\xbe'z $'\xc5\xbd'Z
  $'\xc3\xa4'a $'\xc3\x84'A $'\xc3\xb6'o $'\xc3\x96'O $'\xc3\xbc'u $'\xc3\x9c'U $'\xc4\xbe'l $'\xc4\xbd'L $'\xc4\xba'l $'\xc4\xb9'L
  $'\xc3\xb4'o $'\xc3\x94'O $'\xc5\x95'r $'\xc5\x94'R $'\xc3\xa0'a $'\xc3\x80'A $'\xc3\xa2'a $'\xc3\x82'A $'\xc3\xa8'e $'\xc3\x88'E
  $'\xc3\xaa'e $'\xc3\x8a'E $'\xc3\xab'e $'\xc3\x8b'E $'\xc3\xae'i $'\xc3\x8e'I $'\xc3\xaf'i $'\xc3\x8f'I $'\xc3\xbb'u $'\xc3\x9b'U
  $'\xc3\xb9'u $'\xc3\x99'U $'\xc3\xa7'c $'\xc3\x87'C $'\xc3\xb1'n $'\xc3\x91'N)
for pair in "${accents[@]}"; do
  ascii_name=${ascii_name//"${pair%?}"/"${pair: -1}"}
done
slug=$(printf '%s' "$ascii_name" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-32)
slug=${slug%-}
[ -n "$slug" ] || die "--name must contain at least one letter or digit (a-z, 0-9)"
service="jay-bot-$slug"

case "$provider" in
  anthropic|openai|claude-cli|codex-cli|hermes) ;;
  *) die "--provider must be anthropic, openai, claude-cli, codex-cli or hermes" ;;
esac

if [ "$remove" = 0 ]; then
  [ -n "$owner" ] || die "--owner is required (your handle: Jay > Settings > Identity)"
  owner=$(printf '%s' "$owner" | LC_ALL=C tr '[:lower:]' '[:upper:]' | tr -d ' ')
  IFS=',' read -r -a owners <<<"$owner"
  [ "${#owners[@]}" -gt 0 ] || die "--owner is empty"
  for h in "${owners[@]}"; do
    [[ "$h" =~ ^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]] || die "--owner: '$h' is not a Jay handle (CT-XXXX-XXXX)"
  done
  case "$api" in
    https://*|http://localhost*|http://127.0.0.1*) api=${api%/} ;;
    *) die "--api must be an https:// URL" ;;
  esac
  case "$prompt" in *$'\n'*) [ "$docker" = 0 ] || die "--prompt must be one line with --docker" ;; esac
  if [ "$docker" = 1 ]; then
    case "$provider" in
      claude-cli|codex-cli) die "--provider $provider needs your signed-in CLI on this machine; it cannot run in Docker. Drop --docker." ;;
    esac
  fi
  if [ "$base_url_set" = 1 ]; then
    [ "$provider" = openai ] || die "--base-url is only for --provider openai"
    case "$base_url" in http://*|https://*) base_url=${base_url%/} ;; *) die "--base-url must be an http(s) URL" ;; esac
  fi
  if [ "$hermes_url_set" = 1 ]; then
    [ "$provider" = hermes ] || die "--hermes-url is only for --provider hermes"
  fi
  if [ "$group_replies_set" = 1 ]; then
    [ "$provider" != hermes ] || die "--group-replies is not for --provider hermes (Hermes answers owners only)"
    case "$group_replies" in members|owners) ;; *) die "--group-replies must be members or owners" ;; esac
  fi
  if [ "$fallback_set" = 1 ] && [ "$provider" = hermes ]; then
    die "--fallback is not for --provider hermes (Hermes falls back between its models itself)"
  fi
  # Spec 2026-11-12-llm-bridge-fallback-rescue A5: actions run commands on
  # THIS machine, so neither Hermes (no actions) nor a container fits.
  if [ "$actions_set" = 1 ] || [ -n "$rescue" ]; then
    [ "$provider" != hermes ] || die "--actions and --rescue-hermes are not for --provider hermes"
    [ "$docker" = 0 ] || die "--actions and --rescue-hermes run commands on this machine; drop --docker"
  fi
  case "$actions" in *$'\n'*) die "--actions must be one line" ;; esac
  if [ -n "$log_file_arg" ]; then
    [ -n "$rescue" ] || die "--log-file is only for --rescue-hermes"
    case "$log_file_arg" in /*) ;; *) die "--log-file must be an absolute path" ;; esac
    case "$log_file_arg" in *"'"*|*'"'*|*';'*) die "--log-file must not contain quotes or ;" ;; esac
  fi
  if [ -n "$rescue" ]; then
    [[ "$rescue" =~ ^[A-Za-z0-9@._:-]{1,128}$ ]] || die "--rescue-hermes: '$rescue' is not a systemd unit or launchd label name (letters, digits, @ . _ : -)"
    if [ "$group_replies_set" = 1 ] && [ "$group_replies" != owners ]; then
      die "--rescue-hermes answers owners only; drop --group-replies $group_replies"
    fi
    # A rescue bot must never act for anyone but its owners.
    group_replies=owners group_replies_set=1
  fi
fi

# --- platform -----------------------------------------------------------------
os=${os_override:-$(uname -s)}
arch=${arch_override:-$(uname -m)}
case "$os" in
  Linux|linux) os=linux ;;
  Darwin|macos|darwin) os=macos ;;
  *) [ "$docker" = 1 ] || die "unsupported system '$os': use --docker, or on Windows the PowerShell command" ;;
esac
case "$arch" in
  x86_64|amd64|x64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) [ "$docker" = 1 ] || die "unsupported CPU '$arch': use --docker" ;;
esac
if [ "$docker" = 0 ] && [ "$os" = macos ] && [ "$arch" != arm64 ]; then
  die "Intel Macs have no native bundle yet: use --docker"
fi

bot_dir="$BOTS_DIR/$slug"
env_file="$bot_dir/bot.env"
log_file="$bot_dir/bot.log"
bridge=llm_bridge
[ "$provider" = hermes ] && bridge=hermes_bridge
if [ "$docker" = 1 ]; then
  mode=docker
elif [ "$os" = macos ]; then
  mode=launchd
elif [ -n "$os_override" ]; then
  mode=systemd # dry-run matrix: assume a normal desktop/server
elif command -v systemctl > /dev/null 2>&1 && systemctl --user show-environment > /dev/null 2>&1; then
  mode=systemd
else
  mode=background # no user systemd (WSL1, minimal containers)
fi
plist="$HOME/Library/LaunchAgents/cz.zcloud.$service.plist"
unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$service.service"

# Prints a command (shell-quoted) in dry-run, runs it otherwise.
run() {
  if [ "$dry" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}
note() { if [ "$dry" = 1 ]; then printf '[dry-run] %s\n' "$*"; fi; }

tty_ok() { [ -r /dev/tty ] && [ -w /dev/tty ] && { : < /dev/tty; } 2> /dev/null; }

# Single-quotes $1 for a POSIX sh file: ' -> '\''
shq() { local v=${1//\'/\'\\\'\'}; printf "'%s'" "$v"; }

# Joins dirs into a PATH value, skipping empty and repeated ones.
path_join() {
  local out='' d
  for d in "$@"; do
    [ -n "$d" ] || continue
    case ":$out:" in *":$d:"*) ;; *) out=${out:+$out:}$d ;; esac
  done
  printf '%s' "$out"
}

# Follows symlinks to the real file (portable: no `readlink -f` on older macOS).
resolve_path() {
  local p=$1 link n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    link=$(readlink "$p")
    case "$link" in /*) p=$link ;; *) p="$(dirname "$p")/$link" ;; esac
    n=$((n + 1))
  done
  printf '%s/%s' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}

# Sets interp (the interpreter a script CLI names in its shebang, empty for
# a native binary), interp_bin (its path), interp_env (1 = found via PATH,
# `#!/usr/bin/env`; 0 = an absolute #! path) and interp_dirs (its dir as found on this user's PATH,
# then its real dir if that differs: the first survives a version upgrade,
# the second a removed symlink). Dies when the interpreter is missing.
find_interpreter() { # cli_path
  interp='' interp_dirs=() interp_bin='' interp_env=0
  local line found w
  local -a words
  [ -f "$1" ] && [ -r "$1" ] || return 0 # dry-run matrix: no such file
  [ "$(head -c 2 "$1" 2> /dev/null || true)" = '#!' ] || return 0
  line=$(head -n 1 "$1" | tr -d '\r') # head follows the symlink
  read -r -a words <<<"${line#\#!}"
  [ "${#words[@]}" -gt 0 ] || return 0
  if [ "$(basename "${words[0]}")" = env ]; then
    # `#!/usr/bin/env node`, `#!/usr/bin/env -S node --flag`
    for w in "${words[@]:1}"; do
      case "$w" in
        -S*) w=${w#-S}; [ -n "$w" ] || continue ;;
        -*|*=*) continue ;;
      esac
      interp=$w
      break
    done
    [ -n "$interp" ] || return 0
    found=$(type -P "$interp" || true)
    [ -n "$found" ] || die "$cli at $1 is a script that runs '$interp' (#!${line#\#!}), but '$interp' is not on your PATH. Install it (node: https://nodejs.org) so that '$interp' works in this terminal, then run this command again."
    case "$found" in /*) ;; *) found="$(cd "$(dirname "$found")" && pwd)/$(basename "$found")" ;; esac
    interp_env=1
  else
    found=${words[0]}
    interp=$(basename "$found")
    [ -x "$found" ] || die "$cli at $1 needs the interpreter $found, which does not exist. Reinstall $cli, then run this command again."
  fi
  interp_bin=$found
  interp_dirs=("$(dirname "$found")")
  w=$(dirname "$(resolve_path "$found")")
  [ "$w" = "${interp_dirs[0]}" ] || interp_dirs+=("$w")
}

# Escapes text for an XML element (launchd plist).
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Reads KEY from the existing settings file (rerun = update). The file is
# ours, 600, and written with shq(), so sourcing it in a subshell is safe.
old_value() {
  [ -f "$env_file" ] || return 0
  # shellcheck disable=SC1090
  ( set +u; . "$env_file"; printf '%s' "${!1:-}" )
}

# --- remove -------------------------------------------------------------------
stop_service() {
  case "$mode" in
    systemd)
      if [ -f "$unit" ] || [ "$dry" = 1 ]; then
        run systemctl --user disable --now "$service.service" || true
      fi ;;
    launchd)
      if [ -f "$plist" ] || [ "$dry" = 1 ]; then
        run launchctl bootout "gui/$(id -u)" "$plist" 2> /dev/null || true
      fi ;;
    background)
      if [ -f "$bot_dir/bot.pid" ]; then
        run kill "$(cat "$bot_dir/bot.pid")" 2> /dev/null || true
        run rm -f "$bot_dir/bot.pid"
      fi ;;
    docker)
      run docker rm -f "$service" > /dev/null 2>&1 || true ;;
  esac
}

if [ "$remove" = 1 ]; then
  say "Removing bot '$name' ($service)."
  stop_service
  case "$mode" in
    systemd) run rm -f "$unit"; run systemctl --user daemon-reload ;;
    launchd) run rm -f "$plist" ;;
  esac
  delete=0
  if [ "$yes" = 1 ]; then
    delete=1
  elif [ "$dry" = 0 ] && tty_ok; then
    printf 'Also delete its identity and chat history (%s)? The handle stops working for good. [y/N] ' "$bot_dir" > /dev/tty
    read -r answer < /dev/tty || answer=''
    case "$answer" in y|Y|yes|YES|a|A|ano) delete=1 ;; esac
  else
    note "would ask before deleting the identity in $bot_dir"
  fi
  if [ "$delete" = 1 ]; then
    run rm -rf "$bot_dir"
    [ "$mode" = docker ] && { run docker volume rm "$service" > /dev/null 2>&1 || true; }
    say "Deleted. The bot's identity is gone."
  else
    say "Service removed. Identity kept in $bot_dir$([ "$mode" = docker ] && printf ' and Docker volume %s' "$service")."
    say "Run the setup command again with --name '$name' to bring the same bot back."
  fi
  exit 0
fi

# --- provider chain (spec 2026-11-12-llm-bridge-fallback-rescue F1, F2, F12) --
# --provider first, then every --fallback in order. Same rules as the
# bridge's LLM_FALLBACK check (a known id, no duplicate, not the primary),
# so a bad list stops here instead of the bot exiting with 78 later.
fallbacks=()
if [ "$provider" != hermes ]; then
  fb_hint=''
  if [ "$fallback_set" = 0 ]; then
    fallback=$(old_value LLM_FALLBACK)
    fb_hint=" (stored in $env_file: give --fallback again, or --fallback none)"
  fi
  fallback=$(printf '%s' "$fallback" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -d ' \t')
  [ "$fallback" != none ] || fallback=''
  IFS=',' read -r -a fb_parts <<<"$fallback"
  for f in ${fb_parts[@]+"${fb_parts[@]}"}; do
    [ -n "$f" ] || continue
    case "$f" in
      anthropic|openai|claude-cli|codex-cli) ;;
      *) die "--fallback: '$f' is unknown; use anthropic, openai, claude-cli or codex-cli$fb_hint" ;;
    esac
    [ "$f" != "$provider" ] || die "--fallback: $f is already --provider; list only the providers to try after it$fb_hint"
    for g in ${fallbacks[@]+"${fallbacks[@]}"}; do
      [ "$g" != "$f" ] || die "--fallback: $f is listed twice$fb_hint"
    done
    if [ "$docker" = 1 ]; then
      case "$f" in
        claude-cli|codex-cli) die "--fallback $f needs your signed-in CLI on this machine; it cannot run in Docker. Drop --docker or that fallback." ;;
      esac
    fi
    fallbacks+=("$f")
  done
fi
fallback=''
for f in ${fallbacks[@]+"${fallbacks[@]}"}; do fallback=${fallback:+$fallback,}$f; done
chain=("$provider" ${fallbacks[@]+"${fallbacks[@]}"})
chain_text=$provider
for f in ${fallbacks[@]+"${fallbacks[@]}"}; do chain_text="$chain_text -> $f"; done
has_cli=0
for p in "${chain[@]}"; do
  case "$p" in claude-cli|codex-cli) has_cli=1 ;; esac
done
if [ "$check_only" = 1 ] && [ "$has_cli" = 0 ]; then
  die "--check-only is for claude-cli or codex-cli (as --provider or --fallback)"
fi
# Not secret, so shown (also in dry-run): which provider answers when.
if [ -n "$fallback" ]; then
  say "Provider chain: $chain_text (the next one answers when the one before fails before it sent any text)"
fi

# --- secrets --------------------------------------------------------------------
key_of() {
  case "$1" in
    anthropic) printf ANTHROPIC_API_KEY ;;
    openai) printf OPENAI_API_KEY ;;
    hermes) printf HERMES_API_KEY ;;
  esac
}

store_key=$(old_value BOT_STORE_KEY)
if [ -z "$store_key" ]; then
  if [ "$dry" = 1 ]; then
    note "would generate BOT_STORE_KEY (32 random bytes, never printed)"
  elif command -v openssl > /dev/null 2>&1; then
    store_key=$(openssl rand -base64 32)
  else
    store_key=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
  fi
else
  note "keeps the existing BOT_STORE_KEY (same identity)"
fi

# The API key of every API provider in the chain: from the environment, the
# stored settings, or a hidden prompt (never an argument). key_vars/key_vals
# are parallel lists; a fallback needs its key exactly like --provider (F2).
key_vars=() key_vals=()
for p in "${chain[@]}"; do
  key_var=$(key_of "$p")
  [ -n "$key_var" ] || continue
  role=''
  [ "$p" = "$provider" ] || role=" for --fallback $p"
  api_key=${!key_var:-}
  [ -n "$api_key" ] || api_key=$(old_value "$key_var")
  if [ -z "$api_key" ]; then
    optional=0
    # A local OpenAI-compatible server (Ollama, LM Studio) needs no key.
    [ "$p" = "$provider" ] && [ "$provider" = openai ] && [ "$base_url_set" = 1 ] && optional=1
    if [ "$dry" = 1 ]; then
      note "would ask for $key_var$role with a hidden prompt"
    elif tty_ok; then
      hint=''
      case "$p" in
        anthropic) hint=' (https://platform.claude.com > API keys)' ;;
        openai) [ "$optional" = 1 ] && hint=' (empty if the server needs none)' || hint=' (https://platform.openai.com/api-keys)' ;;
        hermes) hint=" (Hermes' API_SERVER_KEY)" ;;
      esac
      printf '%s%s%s: ' "$key_var" "$role" "$hint" > /dev/tty
      IFS= read -rs api_key < /dev/tty || api_key=''
      printf '\n' > /dev/tty
    fi
    if [ -z "$api_key" ] && [ "$optional" = 0 ] && [ "$dry" = 0 ]; then
      die "$key_var is needed$role: set it in the environment or run this in a terminal"
    fi
  fi
  key_vars+=("$key_var")
  key_vals+=("$api_key")
done

# Keep earlier optional settings on a rerun unless given again.
[ "$model_set" = 1 ] || model=$(old_value LLM_MODEL)
[ "$prompt_set" = 1 ] || prompt=$(old_value LLM_SYSTEM_PROMPT)
[ "$base_url_set" = 1 ] || base_url=$(old_value OPENAI_BASE_URL)
# Only for --provider openai: with an openai fallback a stored custom
# endpoint would make the bridge refuse to start (spec F3).
[ "$provider" = openai ] || base_url=''
[ "$group_replies_set" = 1 ] || group_replies=$(old_value GROUP_REPLIES)
if [ "$provider" = hermes ]; then
  [ "$hermes_url_set" = 1 ] || hermes_url=$(old_value HERMES_URL)
  [ -n "$hermes_url" ] || hermes_url=http://127.0.0.1:8642
fi
if [ "$provider" = openai ] && [ -n "$base_url" ] && [ -z "$model" ]; then
  die "--model is required with --base-url (the endpoint decides which models exist)"
fi

# --- actions (spec 2026-11-12-llm-bridge-fallback-rescue A5) -----------------
# The bridge runs these commands itself, without a shell; the model can only
# name them. Presets per OS for a Hermes rescue bot; --actions adds more.
[ "$actions_set" = 1 ] || actions=$(old_value LLM_ACTIONS)
[ "$actions" != none ] || actions=''
if [ -n "$rescue" ]; then
  if [ "$os" = macos ]; then
    target="gui/$(id -u)/$rescue"
    preset="status=launchctl print $target; restart=launchctl kickstart -k $target"
    if [ -n "$log_file_arg" ]; then
      preset="$preset; logs=tail -n 200 '$log_file_arg'"
    else
      say "Note: launchd keeps no log of its own; add --log-file <Hermes log> for a 'logs' action."
    fi
  else
    preset="status=systemctl --user status $rescue --no-pager; restart=systemctl --user restart $rescue"
    if [ -n "$log_file_arg" ]; then
      preset="$preset; logs=tail -n 200 '$log_file_arg'"
    else
      preset="$preset; logs=journalctl --user -u $rescue -n 200 --no-pager"
    fi
  fi
  if [ "$actions_set" = 1 ] && [ -n "$actions" ]; then
    actions="$preset; $actions"
  else
    actions=$preset
  fi
fi
# Not secret by contract (the bridge logs them too), so shown here.
[ -z "$actions" ] || say "Actions (run by the bot for its owners in 1:1 chats only): $actions"

# --- isolation (spec 2026-11-09-bot-access A7) ----------------------------------------
# On Linux the native bot runs under bubblewrap: the whole home folder is
# replaced by an empty one, only the bot folder (read-write), the CLI and
# its login (claude: ~/.claude + ~/.claude.json, codex: ~/.codex) are
# visible. WHY bubblewrap and not systemd's TemporaryFileSystem=/BindPaths=:
# Ubuntu's default AppArmor rule against unprivileged user namespaces stops
# a user unit from setting up mounts (226/NAMESPACE, or the setting is
# silently ignored), while Ubuntu ships an AppArmor profile that lets bwrap
# do exactly this. Needed because group members, not only the owner, can
# make the bot run the CLI, and codex's read-only sandbox may still READ
# every file of this user. Decided here, before the CLI check, because that
# check starts the CLI the way the service will: inside the sandbox.
sandbox=0
if [ "$os" = linux ] && [ "$docker" = 0 ]; then
  if [ -n "$os_override" ] && [ "$dry" = 1 ] && [ "$check_only" = 0 ]; then
    sandbox=1 # dry-run matrix: assume bubblewrap is installed
  elif command -v bwrap > /dev/null 2>&1 \
    && bwrap --ro-bind / / --unshare-user --die-with-parent true > /dev/null 2>&1; then
    sandbox=1
  fi
fi

# Writes $1 (the bot's sandbox.sh): runs "$@" under bubblewrap (see
# "isolation"). Exposes EVERY CLI of the provider chain (spec F12: a
# fallback CLI must start in the same sandbox), each with its interpreter
# and login. The CLIs' and interpreters' real locations are resolved at
# EVERY start, so a CLI update that moves its files keeps working after a
# restart. Uses the cl_* lists filled in "CLI providers".
write_sandbox() {
  local i clis='' interps='' ireals='' ienvs='' login=''
  for ((i = 0; i < ncli; i++)); do
    clis="$clis $(shq "${cl_paths[$i]}")"
    interps="$interps $(shq "${cl_ibin[$i]}")"
    ireals="$ireals $(shq "${cl_ireal[$i]}")"
    ienvs="$ienvs ${cl_ienv[$i]}"
    # shellcheck disable=SC2016 # expanded later, by sandbox.sh
    case "${cl_names[$i]}" in
      claude) login="$login"'rw "$HOME/.claude"; rw "$HOME/.claude.json"'$'\n' ;;
      codex) login="$login"'rw "${CODEX_HOME:-$HOME/.codex}"'$'\n' ;;
    esac
  done
  cat > "$1" <<EOF
#!/usr/bin/env bash
# Generated by jay-new-bot.sh (spec 2026-11-09-bot-access A7): runs the bot
# in a bubblewrap sandbox. Its home folder is empty; visible are only the bot
# folder (read-write), the system (read-only) and the provider CLIs with
# their interpreters and logins. Try it: sandbox.sh /bin/sh -c 'ls -a ~'
set -eu
DIR=$(shq "$bot_dir")
# Every CLI of the provider chain (LLM_PROVIDER, then LLM_FALLBACK); per CLI
# the interpreter of a script CLI (npm: node) as found on the PATH, its real
# file at install time, and 1 when the CLI finds it via PATH.
CLIS=(${clis# })
INTERPS=(${interps# })
INTERP_REALS=(${ireals# })
INTERP_ENVS=(${ienvs# })
a=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs "\$HOME")
# The session bus, keyring and agent sockets of the user live here.
if [ -d "/run/user/\$(id -u)" ]; then a+=(--tmpfs "/run/user/\$(id -u)"); fi
# (Missing only during the install-time check of a new bot.)
if [ -d "\$DIR" ]; then a+=(--bind "\$DIR" "\$DIR"); fi
# Never re-expose the whole home folder (or more) by accident.
ok() { case "\$1" in "\$HOME"|"\$HOME/"|/|"") return 1 ;; esac; case "\$HOME/" in "\$1"/*) return 1 ;; esac; }
ro() { if [ -e "\$1" ] && ok "\$1"; then a+=(--ro-bind "\$1" "\$1"); fi; }
rw() { if [ -e "\$1" ] && ok "\$1"; then a+=(--bind "\$1" "\$1"); fi; }
# An executable and the folder it really lives in (npm: the node_modules
# tree, Claude Code: its versions folder); a symlink is recreated as such.
exe() {
  local real
  real=\$(readlink -f "\$1")
  case "\$real" in
    */node_modules/*) ro "\${real%%/node_modules/*}/node_modules" ;;
    *) ro "\$(dirname "\$real")" ;;
  esac
  if [ -L "\$1" ]; then a+=(--symlink "\$(readlink "\$1")" "\$1"); fi
}
seen='' ipath='' n=0 i=0
while [ "\$i" -lt "\${#CLIS[@]}" ]; do
  exe "\${CLIS[\$i]}"
  INTERP=\${INTERPS[\$i]}
  if [ -n "\$INTERP" ]; then
    # The path found on the PATH survives an upgrade, the real one a
    # removed symlink.
    if [ -e "\$INTERP" ]; then real=\$(readlink -f "\$INTERP"); else real=\${INTERP_REALS[\$i]}; fi
    case "\$real" in
      "\$HOME"/*)
        if [ "\${INTERP_ENVS[\$i]}" = 1 ]; then
          # In the home folder (nvm, a tarball under ~/.hermes): bind only
          # its folder, at a neutral path first on PATH, so the folders
          # around it (and their names) stay hidden. One per distinct folder.
          d=\$(dirname "\$real")
          case "\$seen" in
            *"<\$d>"*) ;;
            *)
              seen="\$seen<\$d>"
              n=\$((n + 1))
              t="\$HOME/.jay-interp/bin"
              if [ "\$n" != 1 ]; then t="\$t\$n"; fi
              a+=(--ro-bind "\$d" "\$t")
              ipath="\${ipath:+\$ipath:}\$t" ;;
          esac
        else
          exe "\$INTERP" # an absolute #! path must stay where it is
        fi ;;
      *) ;; # system folders are visible read-only anyway
    esac
  fi
  i=\$((i + 1))
done
if [ -n "\$ipath" ]; then a+=(--setenv PATH "\$ipath:\$PATH"); fi
# The logins of the CLIs above.
$login
exec bwrap "\${a[@]}" --unshare-user --unshare-pid --unshare-ipc --die-with-parent --new-session -- "\$@"
EOF
  chmod 700 "$1"
}

# Prints the cli-<name>.sh wrapper of CLI number $1 (spec A6, F12): with
# actions the bot starts every CLI through its wrapper, so only the CLIs
# run in the sandbox. The last line is the command (shown in dry-run).
cli_wrapper() {
  printf '#!/bin/sh\n'
  printf '# Generated by jay-new-bot.sh: runs %s in the bot sandbox (spec A6).\n' "${cl_names[$1]}"
  printf 'exec %s %s "$@"\n' "$(shq "$bot_dir/sandbox.sh")" "$(shq "${cl_paths[$1]}")"
}

# Joins words as "a", "a and b", "a, b and c".
and_join() {
  local out='' i=0
  for w in "$@"; do
    i=$((i + 1))
    if [ "$i" = 1 ]; then out=$w
    elif [ "$i" = "$#" ]; then out="$out and $w"
    else out="$out, $w"; fi
  done
  printf '%s' "$out"
}

# --- CLI providers: the owner's own, signed-in CLIs --------------------------------
# One entry per CLI of the chain (primary and fallbacks, spec F12), the same
# detection for each: cl_names (claude|codex), cl_vars (CLAUDE_BIN|CODEX_BIN),
# cl_paths, cl_interp (interpreter name), cl_ibin, cl_ienv, cl_ireal (see
# find_interpreter). Their dirs form one service PATH.
cl_names=() cl_vars=() cl_paths=() cl_interp=() cl_ibin=() cl_ienv=() cl_ireal=() svc_dirs=()
service_path='' interp='' interp_bin='' interp_env=0
for p in "${chain[@]}"; do
  case "$p" in
    claude-cli) cli_var=CLAUDE_BIN; cli=claude ;;
    codex-cli) cli_var=CODEX_BIN; cli=codex ;;
    *) continue ;;
  esac
  role=''
  [ "$p" = "$provider" ] || role=" (needed by --fallback $p)"
  if [ -n "${!cli_var:-}" ]; then
    cli_path=${!cli_var} # an explicit choice, e.g. a second install
    if [ ! -f "$cli_path" ] || [ ! -x "$cli_path" ]; then die "$cli_var=$cli_path is not an executable file$role"; fi
  elif [ -n "$os_override" ]; then
    cli_path="/usr/local/bin/$cli" # dry-run matrix on a machine without it
  else
    cli_path=$(command -v "$cli" || true)
  fi
  if [ -z "$cli_path" ]; then
    if [ "$cli" = claude ]; then
      die "Claude Code (claude) is not installed$role. Install it (https://code.claude.com/docs/en/setup), run 'claude' once and sign in with your Claude account, then run this command again."
    else
      die "Codex CLI (codex) is not installed$role. Install it (https://developers.openai.com/codex/cli), run 'codex login', then run this command again."
    fi
  fi
  # A service has a minimal PATH, so the bot gets the absolute path.
  case "$cli_path" in /*) ;; *) cli_path="$(cd "$(dirname "$cli_path")" && pwd)/$(basename "$cli_path")" ;; esac
  # ...and the interpreter of a script CLI: npm installs claude/codex as
  # `#!/usr/bin/env node` scripts, and node often lives in a non-standard
  # dir (nvm, a tarball), so the service would fail with exit 127.
  find_interpreter "$cli_path"
  cl_names+=("$cli")
  cl_vars+=("$cli_var")
  cl_paths+=("$cli_path")
  cl_interp+=("$interp")
  cl_ibin+=("$interp_bin")
  cl_ienv+=("$interp_env")
  if [ -n "$interp_bin" ]; then cl_ireal+=("$(resolve_path "$interp_bin")"); else cl_ireal+=(''); fi
  svc_dirs+=(${interp_dirs[@]+"${interp_dirs[@]}"} "$(dirname "$cli_path")")
done
ncli=${#cl_names[@]}
clis_text=$(and_join ${cl_names[@]+"${cl_names[@]}"})
# Distinct interpreter names, e.g. "node".
interps_text=''
for ((i = 0; i < ncli; i++)); do
  [ -n "${cl_interp[$i]}" ] || continue
  case " $interps_text " in *" ${cl_interp[$i]} "*) ;; *) interps_text="${interps_text:+$interps_text }${cl_interp[$i]}" ;; esac
done
# shellcheck disable=SC2086 # split the distinct names on purpose
interps_text=$(and_join $interps_text)
if [ "$ncli" -gt 0 ]; then
  service_path=$(path_join "${svc_dirs[@]}" /usr/local/bin /usr/bin /bin)
  # The check runs every CLI the way the service will: with the service PATH,
  # an empty environment and, on Linux, inside the same bubblewrap sandbox
  # (a CLI or interpreter the sandbox does not bind fails here, not later).
  where=''
  [ "$sandbox" = 1 ] && where=' in the bubblewrap sandbox'
  if [ "$dry" = 1 ] && [ "$check_only" = 0 ]; then
    needs='needs'
    [ "$ncli" = 1 ] || needs='need'
    note "service PATH=$service_path${interps_text:+ (includes the dir of $interps_text, which $clis_text $needs)}"
    for ((i = 0; i < ncli; i++)); do
      check_cmd=(env -i "HOME=$HOME" "PATH=$service_path")
      [ "$sandbox" = 1 ] && check_cmd+=("$bot_dir/sandbox.sh")
      check_cmd+=("${cl_paths[$i]}" --version)
      note "would check that ${cl_names[$i]} starts the way the service starts it$where:$(printf ' %q' "${check_cmd[@]}")"
    done
  else
    # Before anything is written or started: a bot that cannot start its
    # CLI would only answer every message with an error.
    check_dir=''
    if [ "$sandbox" = 1 ]; then
      check_dir=$(mktemp -d "${TMPDIR:-/tmp}/jay-bot-check.XXXXXX")
      write_sandbox "$check_dir/sandbox.sh"
    fi
    for ((i = 0; i < ncli; i++)); do
      cli=${cl_names[$i]} interp=${cl_interp[$i]}
      check_cmd=(env -i "HOME=$HOME" "PATH=$service_path")
      [ -z "$check_dir" ] || check_cmd+=("$check_dir/sandbox.sh")
      check_cmd+=("${cl_paths[$i]}" --version)
      check_rc=0
      check_out=$("${check_cmd[@]}" 2>&1) || check_rc=$?
      if [ "$check_rc" != 0 ]; then
        [ -z "$check_dir" ] || rm -rf "$check_dir"
        check_out=$(printf '%s\n' "$check_out" | head -n 3 | tr '\n' ' ')
        if [ -n "$interp" ] && { [ "$check_rc" = 127 ] || [ "$check_rc" = 126 ] || grep -qiE 'no such file|not found' <<<"$check_out"; }; then
          die "$interp (or something it needs) is not found in the bot service PATH ($service_path): '$cli --version' failed with exit $check_rc: $check_out. Install $interp in a standard place (/usr/local/bin or /usr/bin), or make sure '$interp' and what it needs work from that PATH, then run this command again."
        fi
        die "$cli at ${cl_paths[$i]} does not start with the bot service PATH ($service_path)$where: '$cli --version' failed with exit $check_rc: $check_out"
      fi
      say "Checked: $cli starts with the bot service PATH ($service_path)$where."
    done
    [ -z "$check_dir" ] || rm -rf "$check_dir"
  fi
  for ((i = 0; i < ncli; i++)); do
    cli=${cl_names[$i]}
    if [ "$dry" = 0 ] || [ "$check_only" = 1 ]; then
      if [ "$cli" = claude ]; then
        "${cl_paths[$i]}" auth status > /dev/null 2>&1 || say "Warning: 'claude auth status' says you are not signed in. Run 'claude' and sign in, or the bot will answer with an error."
      else
        "${cl_paths[$i]}" login status > /dev/null 2>&1 || say "Warning: 'codex login status' says you are not signed in. Run 'codex login', or the bot will answer with an error."
      fi
    fi
    say "Using your own $cli at ${cl_paths[$i]} (personal use only; Jay never sees your login)."
  done
  if [ "$check_only" = 1 ]; then exit 0; fi
fi

# Spec A6: with actions the bridge must reach the service manager (systemd
# D-Bus, launchctl), which the sandbox hides. So on Linux the sandbox then
# wraps only the CLI processes (cli-<name>.sh as CLAUDE_BIN/CODEX_BIN, one
# per CLI of the chain), not the bridge.
split_sandbox=0
if [ "$sandbox" = 1 ] && [ -n "$actions" ]; then split_sandbox=1; fi
# The value of CLAUDE_BIN/CODEX_BIN for CLI number $1.
cli_setting() {
  if [ "$split_sandbox" = 1 ]; then printf '%s' "$bot_dir/cli-${cl_names[$1]}.sh"; else printf '%s' "${cl_paths[$1]}"; fi
}

# Spec F8: owners only by default when ANY provider of the chain is a CLI.
effective_replies=$group_replies
if [ -z "$effective_replies" ] && [ "$provider" != hermes ]; then
  effective_replies=members
  [ "$ncli" -gt 0 ] && effective_replies=owners
fi
if [ "$split_sandbox" = 1 ] && [ "$ncli" -gt 0 ]; then
  say "Isolation: $clis_text $([ "$ncli" = 1 ] && printf runs || printf run) in a bubblewrap sandbox (sees only $bot_dir and what it needs); the bot itself runs outside it, so its actions reach the service manager."
elif [ "$split_sandbox" = 1 ]; then
  say "Isolation: none needed for $chain_text; with actions the bot runs outside the sandbox (its actions must reach the service manager)."
elif [ "$sandbox" = 1 ]; then
  say "Isolation: the bot runs in a bubblewrap sandbox (sees only $bot_dir and what its providers need)."
elif [ "$docker" = 0 ]; then
  if [ "$ncli" -gt 0 ] && [ "$effective_replies" = members ]; then
    say "WARNING: group members can make this bot run your $clis_text, and there is no sandbox here."
    if [ "$os" = linux ]; then
      say "  Install bubblewrap (e.g. 'sudo apt install bubblewrap') and run this command again,"
    else
      say "  macOS has no sandbox for it in this setup. Run the bot under a separate macOS user,"
    fi
    say "  or use --group-replies owners. See infra/bots/README.md."
  elif [ "$os" = linux ]; then
    say "Note: bubblewrap (bwrap) is not available, so the bot runs without a sandbox."
  fi
fi

# --- settings file ------------------------------------------------------------------
write_settings() {
  local tmp="$env_file.tmp" store_path=$1 quote=$2
  emit() { # KEY VALUE
    [ -n "$2" ] || return 0
    if [ "$quote" = 1 ]; then printf '%s=%s\n' "$1" "$(shq "$2")"; else printf '%s=%s\n' "$1" "$2"; fi
  }
  {
    [ "$quote" = 1 ] && printf '# Jay bot settings, written by jay-new-bot.sh. Contains secrets: keep it private (600).\n'
    emit CALLTYPE_API_URL "$api"
    emit BOT_STORE_PATH "$store_path"
    emit BOT_STORE_KEY "$store_key"
    emit ALLOWED_HANDLES "$owner"
    emit BOT_DISPLAY_NAME "$name"
    if [ "$provider" = hermes ]; then
      emit HERMES_URL "$hermes_url"
      emit HERMES_API_KEY "${key_vals[0]:-}"
    else
      emit LLM_PROVIDER "$provider"
      emit LLM_FALLBACK "$fallback"
      emit LLM_MODEL "$model"
      emit LLM_SYSTEM_PROMPT "$prompt"
      for ((k = 0; k < ${#key_vars[@]}; k++)); do emit "${key_vars[$k]}" "${key_vals[$k]}"; done
      emit OPENAI_BASE_URL "$base_url"
      emit GROUP_REPLIES "$group_replies"
      for ((k = 0; k < ncli; k++)); do emit "${cl_vars[$k]}" "$(cli_setting "$k")"; done
      emit LLM_ACTIONS "$actions"
    fi
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$env_file"
}

say "Setting up bot '$name' for $owner ($chain_text, $mode) in $bot_dir"
run mkdir -p "$bot_dir"
run chmod 700 "$bot_dir"

# --- docker ---------------------------------------------------------------------------
wait_ready() { # $1 = function printing the log since the start
  local out=''
  for _ in $(seq 1 90); do
    out=$("$1" 2>&1 || true)
    if printf '%s\n' "$out" | grep -q 'Connected\.'; then
      printf '%s\n' "$out"
      return 0
    fi
    # Every normal log line starts with a timestamp; anything else is an
    # error the bridge printed before exiting.
    if printf '%s\n' "$out" | grep -q '^[^0-9]'; then
      printf '%s\n' "$out" | tail -n 15 >&2
      return 1
    fi
    sleep 1
  done
  printf '%s\n' "$out" | tail -n 15 >&2
  return 1
}

report() { # $1 = log text
  local handle invite
  handle=$(printf '%s\n' "$1" | grep -o 'CT-[A-Z0-9]\{4\}-[A-Z0-9]\{4\}' | head -n 1 || true)
  invite=$(printf '%s\n' "$1" | grep -o 'ct://[^ ]*' | head -n 1 || true)
  say ""
  say "Bot '$name' is running."
  [ -n "$handle" ] && say "  Handle: $handle"
  [ -n "$invite" ] && say "  Invite: $invite"
  if [ "$provider" = hermes ]; then
    say "Open Jay and add the bot by its handle (or paste the invite)."
  else
    say "Check Jay: the bot just wrote to you (first start only). Reply to it to start chatting."
  fi
  say "Update: run the same command again. Remove: add --remove."
}

if [ "$mode" = docker ]; then
  command -v docker > /dev/null 2>&1 || [ "$dry" = 1 ] || die "docker is not installed"
  image=$IMAGE_LLM
  [ "$provider" = hermes ] && image=$IMAGE_HERMES
  if [ "$dry" = 1 ]; then
    note "would write $env_file (600) for --env-file: settings and secrets, values hidden"
  else
    # Docker's --env-file takes raw KEY=value lines (no quoting); the store
    # path is the image's /data/bot.store on the named volume.
    write_settings /data/bot.store 0
  fi
  run docker pull "$image"
  run docker rm -f "$service" > /dev/null 2>&1 || true
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run docker run -d --name "$service" --restart unless-stopped \
    --env-file "$env_file" -v "$service:/data" "$image"
  if [ "$dry" = 1 ]; then
    note "would wait for 'Connected.' in docker logs $service and print the handle"
    exit 0
  fi
  # shellcheck disable=SC2317,SC2329 # called through wait_ready
  docker_log() { docker logs --since "$since" "$service" 2>&1; }
  out=$(wait_ready docker_log) || die "the bot did not start; see 'docker logs $service'"
  report "$out"
  exit 0
fi

# --- native bundle -------------------------------------------------------------------
asset="jay-${bridge//_/-}-$os-$arch.zip"
url="$BUNDLE_BASE/$asset"

download() { # url file
  if command -v curl > /dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget > /dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "curl or wget is needed"; fi
}
sha256() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
unpack() { # zip dir
  if command -v unzip > /dev/null 2>&1; then unzip -q -o "$1" -d "$2"
  elif command -v bsdtar > /dev/null 2>&1; then bsdtar -xf "$1" -C "$2"
  elif command -v python3 > /dev/null 2>&1; then python3 -m zipfile -e "$1" "$2"
  else die "unzip (or bsdtar or python3) is needed"; fi
}

if [ "$dry" = 1 ]; then
  note "would download $url and check it against $BUNDLE_BASE/SHA256SUMS"
  stop_service
  note "would unpack it to $bot_dir/app (replacing an older version)"
else
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jay-bot.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  say "Downloading $asset ..."
  download "$url" "$tmp/$asset" || die "download failed: $url"
  download "$BUNDLE_BASE/SHA256SUMS" "$tmp/SHA256SUMS" || die "download failed: $BUNDLE_BASE/SHA256SUMS"
  want=$(grep " \*\{0,1\}$asset\$" "$tmp/SHA256SUMS" | cut -d' ' -f1 || true)
  [ -n "$want" ] || die "$asset is not listed in SHA256SUMS"
  [ "$(sha256 "$tmp/$asset")" = "$want" ] || die "checksum mismatch for $asset (download damaged?); nothing was changed"
  mkdir -p "$tmp/app"
  unpack "$tmp/$asset" "$tmp/app"
  chmod +x "$tmp/app/bin/"*
  # Only now, with a verified bundle, stop a running bot (an update keeps
  # the old bot running when the download fails).
  stop_service
  rm -rf "$bot_dir/app.old"
  [ -d "$bot_dir/app" ] && mv "$bot_dir/app" "$bot_dir/app.old"
  mv "$tmp/app" "$bot_dir/app"
  rm -rf "$bot_dir/app.old"
  # curl sets no quarantine flag, but a copied folder might carry one.
  if [ "$os" = macos ]; then xattr -dr com.apple.quarantine "$bot_dir/app" 2> /dev/null || true; fi
fi

if [ "$dry" = 1 ]; then
  note "would write $env_file (600): settings and secrets, values hidden"
  note "would write $bot_dir/run.sh (loads the settings, starts app/bin/$bridge, logs to $log_file${service_path:+, PATH=$service_path})"
  if [ "$sandbox" = 1 ] && { [ "$split_sandbox" = 0 ] || [ "$ncli" -gt 0 ]; }; then
    sb_clis=''
    if [ "$ncli" = 1 ]; then sb_clis=", $clis_text read-only and its login"
    elif [ "$ncli" -gt 1 ]; then sb_clis=", $clis_text read-only with their logins"; fi
    note "would write $bot_dir/sandbox.sh (bubblewrap: empty home, only $bot_dir read-write$sb_clis${interps_text:+, $interps_text read-only})"
  fi
  if [ "$split_sandbox" = 1 ]; then
    note "run.sh starts the bot outside the sandbox (actions need the service manager)"
    for ((k = 0; k < ncli; k++)); do
      note "would write $(cli_setting "$k") as ${cl_vars[$k]}: $(cli_wrapper "$k" | tail -n 1)"
    done
  fi
else
  mkdir -p "$bot_dir/data"
  write_settings "$bot_dir/data/bot.store" 1
  path_line=''
  # The CLI providers start a CLI (and its interpreter): give them the
  # PATH checked above instead of the service manager's minimal one.
  [ -n "$service_path" ] && path_line="PATH=$(shq "$service_path"); export PATH"
  launcher=''
  # shellcheck disable=SC2016 # $DIR is run.sh's own variable
  [ "$sandbox" = 1 ] && [ "$split_sandbox" = 0 ] && launcher='"$DIR/sandbox.sh" '
  cat > "$bot_dir/run.sh" <<EOF
#!/bin/sh
# Generated by jay-new-bot.sh: starts the bot '$slug' with its settings.
DIR=$(shq "$bot_dir")
$path_line
set -a
. "\$DIR/bot.env"
set +a
# Keep one old log, so the log cannot grow without bound.
if [ -f "\$DIR/bot.log" ] && [ "\$(wc -c < "\$DIR/bot.log")" -gt 5000000 ]; then
  mv -f "\$DIR/bot.log" "\$DIR/bot.log.1"
fi
exec ${launcher}"\$DIR/app/bin/$bridge" >> "\$DIR/bot.log" 2>&1
EOF
  chmod 700 "$bot_dir/run.sh"
  if [ "$sandbox" = 1 ] && { [ "$split_sandbox" = 0 ] || [ "$ncli" -gt 0 ]; }; then
    write_sandbox "$bot_dir/sandbox.sh"
  else
    rm -f "$bot_dir/sandbox.sh"
  fi
  # One wrapper per CLI of the chain; drop those of an earlier setup.
  rm -f "$bot_dir/cli.sh" "$bot_dir/cli-claude.sh" "$bot_dir/cli-codex.sh"
  if [ "$split_sandbox" = 1 ]; then
    for ((k = 0; k < ncli; k++)); do
      cli_wrapper "$k" > "$(cli_setting "$k")"
      chmod 700 "$(cli_setting "$k")"
    done
  fi
fi

start_offset=0
[ -f "$log_file" ] && start_offset=$(wc -c < "$log_file")

case "$mode" in
  systemd)
    if [ "$dry" = 1 ]; then
      note "would write $unit (Restart=on-failure, no restart on exit 78 = config error, NoNewPrivileges=yes)"
    else
      mkdir -p "$(dirname "$unit")"
      cat > "$unit" <<EOF
[Unit]
Description=Jay bot $slug
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/sh "$bot_dir/run.sh"
Restart=on-failure
RestartSec=10
# 78 = configuration error: restarting cannot fix it.
RestartPreventExitStatus=78
# Hardening that works in a user unit everywhere. File isolation is done by
# sandbox.sh (bubblewrap): mount options here (TemporaryFileSystem=,
# BindPaths=) fail or are ignored under Ubuntu's AppArmor userns rule.
NoNewPrivileges=yes

[Install]
WantedBy=default.target
EOF
    fi
    run systemctl --user daemon-reload
    run systemctl --user enable "$service.service"
    run systemctl --user restart "$service.service"
    linger=$(loginctl show-user "$(id -un)" --property=Linger 2> /dev/null || true)
    if [ "$linger" != "Linger=yes" ]; then
      say "Note: the bot stops when you log out. To keep it running (also after a reboot without login), run once:"
      say "  sudo loginctl enable-linger $(id -un)"
    fi
    ;;
  launchd)
    if [ "$dry" = 1 ]; then
      note "would write $plist (RunAtLoad, KeepAlive on failure${service_path:+, PATH=$service_path})"
    else
      mkdir -p "$(dirname "$plist")"
      env_xml=''
      [ -n "$service_path" ] && env_xml="  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(xml_escape "$service_path")</string></dict>"
      cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>cz.zcloud.$service</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>$bot_dir/run.sh</string></array>
$env_xml
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
EOF
    fi
    run launchctl bootstrap "gui/$(id -u)" "$plist"
    ;;
  background)
    say "No user systemd here: starting the bot in the background. It will NOT start again after a reboot."
    if [ "$dry" = 0 ]; then
      nohup /bin/sh "$bot_dir/run.sh" > /dev/null 2>&1 &
      echo $! > "$bot_dir/bot.pid"
    fi
    ;;
esac

if [ "$dry" = 1 ]; then
  note "would wait for 'Connected.' in $log_file and print the handle and invite"
  exit 0
fi

say "Starting ..."
# shellcheck disable=SC2329 # called through wait_ready
native_log() { tail -c "+$((start_offset + 1))" "$log_file" 2> /dev/null; }
if ! out=$(wait_ready native_log); then
  # A config error would only loop under launchd; stop it there.
  if [ "$mode" = launchd ]; then launchctl bootout "gui/$(id -u)" "$plist" 2> /dev/null || true; fi
  die "the bot did not start (log: $log_file)"
fi
report "$out"
