#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# version.sh <commit_sha> [build_number_offset]  (stream P, P2)
# ---------------------------------------------------------------------------
# Computes the ONE version every platform build of a commit carries:
#   build_name   = major.minor.patch from pubspec.yaml `version:` at that SHA
#   build_number = number of commits reachable from the SHA (+ offset)
#   msix_version = major.minor.build_number.0
#   commit_sha   = the resolved full SHA
#
# Why the commit count and not github.run_number: every workflow has its own
# run counter, so deploy.yml (web) and release-native.yml (stores) would show
# different numbers for the same bytes. The commit count is deterministic per
# SHA and grows monotonically along master — which is why the SHA must be an
# ancestor of master (a side branch could have a smaller count than a build
# already uploaded) and why a shallow clone is refused (its count is wrong).
#
# Limits: Windows FILEVERSION / MSIX parts are 16-bit (<= 65535) and the Store
# requires revision 0; Android versionCode and iOS CFBundleVersion are far
# larger, so 65535 is the binding limit for every platform.
#
# Output: key=value lines on stdout; also appended to $GITHUB_OUTPUT when set.
# Env overrides (used by test-version.sh): JAY_RELEASE_REF (default
# origin/master), JAY_PUBSPEC_PATH (default src/client/calltype/pubspec.yaml).
# JAY_ALLOW_NON_MASTER=true turns the master check into a warning (deploy.yml
# only, never for store uploads).
# ---------------------------------------------------------------------------
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: version.sh <commit_sha> [build_number_offset]"
SHA=$1
OFFSET=${2:-0}
RELEASE_REF=${JAY_RELEASE_REF:-origin/master}
PUBSPEC=${JAY_PUBSPEC_PATH:-src/client/calltype/pubspec.yaml}
MAX_PART=65535

# A branch or tag name would make the release depend on what that name points
# at when the job runs; only an exact SHA ties tests, builds and manifests
# to the same bytes (same rule as deploy.yml).
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "commit_sha must be a full 40-character lowercase SHA, got '$SHA'"
[[ "$OFFSET" =~ ^[0-9]+$ ]] || fail "build_number_offset must be a non-negative integer, got '$OFFSET'"

[ "$(git rev-parse --is-shallow-repository)" = "false" ] ||
  fail "shallow clone: the commit count would be wrong. Use actions/checkout with fetch-depth: 0 (locally: git fetch --unshallow)."

git cat-file -e "$SHA^{commit}" 2>/dev/null || fail "commit $SHA does not exist in this clone"
git rev-parse --verify --quiet "$RELEASE_REF^{commit}" >/dev/null || fail "release ref $RELEASE_REF not found (fetch-depth: 0 fetches it)"
if ! git merge-base --is-ancestor "$SHA" "$RELEASE_REF"; then
  # deploy.yml (API + web to beta) may ship a branch commit: the web has no
  # store that rejects a lower build number, and blocking it would stop
  # integration-branch deploys. Store releases (release-native.yml) never set
  # this, so their numbers stay monotonic.
  if [ "${JAY_ALLOW_NON_MASTER:-false}" = true ]; then
    echo "::warning::commit $SHA is not on $RELEASE_REF; its build number may be lower than an earlier release."
  else
    fail "commit $SHA is not on $RELEASE_REF. Release only from master so build numbers stay monotonic."
  fi
fi

PUBSPEC_TEXT=$(git show "$SHA:$PUBSPEC" 2>/dev/null) || fail "$PUBSPEC not found at $SHA"
VERSION_LINE=$(printf '%s\n' "$PUBSPEC_TEXT" | grep -E '^version:' | head -n 1 || true)
# The +N part is required but ignored: it only serves local builds.
re='^version:[[:space:]]*([0-9]+)\.([0-9]+)\.([0-9]+)\+[0-9]+[[:space:]]*$'
[[ "$VERSION_LINE" =~ $re ]] || fail "pubspec version must look like 'version: 1.2.3+1', got '$VERSION_LINE'"
MAJOR=$((10#${BASH_REMATCH[1]}))
MINOR=$((10#${BASH_REMATCH[2]}))
PATCH=$((10#${BASH_REMATCH[3]}))
[ "$MAJOR" -le "$MAX_PART" ] && [ "$MINOR" -le "$MAX_PART" ] ||
  fail "major/minor must be <= $MAX_PART (MSIX version parts are 16-bit)"

COUNT=$(git rev-list --count "$SHA")
BUILD_NUMBER=$((COUNT + 10#$OFFSET))
[ "$BUILD_NUMBER" -le "$MAX_PART" ] ||
  fail "build number $BUILD_NUMBER exceeds $MAX_PART (Windows FILEVERSION/MSIX limit)"

BUILD_NAME="$MAJOR.$MINOR.$PATCH"
MSIX_VERSION="$MAJOR.$MINOR.$BUILD_NUMBER.0"

out() {
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}
out build_name "$BUILD_NAME"
out build_number "$BUILD_NUMBER"
out msix_version "$MSIX_VERSION"
out commit_sha "$SHA"
