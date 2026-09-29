#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-version.sh — tests for version.sh against a throw-away git repo
# ---------------------------------------------------------------------------
# Run locally or in ci.yml `platform-config`. Needs only bash + git. Builds a
# tiny history (3 commits on master + 1 on a side branch) in mktemp -d, so it
# never depends on, or touches, the real repository.
# ---------------------------------------------------------------------------
# `cond && ok || bad` is used as an assertion one-liner on purpose: ok/bad
# always return 0, so the if-then-else pitfall SC2015 warns about cannot occur.
# shellcheck disable=SC2015
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION_SH="$HERE/version.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failures=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { failures=$((failures + 1)); echo "FAIL - $1"; }

# Isolated identity and config: the developer's global git config (signing,
# hooks, default branch) must not change what the test sees.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

REPO="$TMP/repo"
mkdir -p "$REPO/src/client/calltype"
cd "$REPO"
git init -q -b master .
commit() { # <version line>
  printf 'name: calltype\n# comment\n%s\n' "$1" >src/client/calltype/pubspec.yaml
  git add -A
  git commit -q -m "c" --allow-empty
  git rev-parse HEAD
}
C1=$(commit 'version: 1.0.0+1')
C2=$(commit 'version: 1.2.0+7')
C3=$(commit 'version: 1.2.3+1')
git checkout -q -b side
SIDE=$(commit 'version: 9.9.9+1')
git checkout -q master

# Local branch stands in for origin/master in the throw-away repo.
export JAY_RELEASE_REF=master
run() { bash "$VERSION_SH" "$@" 2>&1; }
get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

o=$(run "$C3") && [ "$(get "$o" build_number)" = 3 ] && [ "$(get "$o" build_name)" = 1.2.3 ] &&
  [ "$(get "$o" msix_version)" = 1.2.3.0 ] && [ "$(get "$o" commit_sha)" = "$C3" ] &&
  ok "HEAD of master: 1.2.3 (3), msix 1.2.3.0" || bad "HEAD of master: $o"

o=$(run "$C1") && [ "$(get "$o" build_number)" = 1 ] && [ "$(get "$o" build_name)" = 1.0.0 ] &&
  ok "first commit: 1.0.0 (1)" || bad "first commit: $o"

o=$(run "$C2" 5) && [ "$(get "$o" build_number)" = 7 ] && [ "$(get "$o" msix_version)" = 1.2.7.0 ] &&
  ok "offset 5 on commit 2 gives 7" || bad "offset: $o"

GITHUB_OUTPUT="$TMP/gh_out" run "$C3" >/dev/null &&
  grep -qx 'build_number=3' "$TMP/gh_out" && grep -qx "commit_sha=$C3" "$TMP/gh_out" &&
  ok "writes \$GITHUB_OUTPUT" || bad "GITHUB_OUTPUT not written"

o=$(run "$SIDE") && bad "side-branch commit accepted: $o" ||
  { printf '%s' "$o" | grep -q 'is not on master' && ok "side-branch commit rejected" || bad "side branch msg: $o"; }

o=$(run master) && bad "branch name accepted" || ok "branch name instead of SHA rejected"
o=$(run "${C3:0:12}") && bad "short SHA accepted" || ok "short SHA rejected"
o=$(run "$C3" -1) && bad "negative offset accepted" || ok "negative offset rejected"
o=$(run "$(printf 'a%.0s' {1..40})") && bad "unknown SHA accepted" || ok "unknown SHA rejected"

# Bad version lines, each on master so only the format check can fail.
for v in 'version: 1.2+3' 'version: 1.2.3' 'version: v1.2.3+1' 'version: 70000.0.0+1'; do
  B=$(commit "$v")
  o=$(run "$B") && bad "accepted '$v': $o" || ok "rejected '$v'"
done

# Build number over the 16-bit limit via the offset.
o=$(run "$C3" 65533) && bad "65536 accepted" || ok "build number > 65535 rejected"
o=$(run "$C3" 65532) && [ "$(get "$o" build_number)" = 65535 ] && ok "build number 65535 accepted" || bad "65535: $o"

# A shallow clone would count too few commits.
git clone -q --depth 1 "file://$REPO" "$TMP/shallow"
HEADSHA=$(git -C "$TMP/shallow" rev-parse HEAD)
o=$(cd "$TMP/shallow" && run "$HEADSHA") && bad "shallow clone accepted: $o" ||
  { printf '%s' "$o" | grep -q shallow && ok "shallow clone rejected" || bad "shallow msg: $o"; }

echo "# $pass passed, $failures failed"
[ "$failures" -eq 0 ]
