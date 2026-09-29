#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-manifest.sh <out.json> <artifact path> [key=value | key:=json ...]
# ---------------------------------------------------------------------------
# Writes the build manifest that travels next to every released artifact
# (deploy.yml web, _release-*.yml). One writer so every platform records the
# same fields and a manifest can be matched to a store build by
# commitSha + buildNumber (docs/acceptance/matrix.md R-04).
#
# Always present: artifactSha256 (a file's hash, or for a directory the hash
# of the sorted per-file hash list — same rule deploy.yml always used) and
# flutterVersion when flutter is on PATH. Extra fields: key=value adds a
# string, key:=json adds raw JSON (numbers, booleans).
# ---------------------------------------------------------------------------
set -euo pipefail

[ $# -ge 2 ] || {
  echo "usage: build-manifest.sh <out.json> <artifact path> [key=value | key:=json ...]" >&2
  exit 2
}
OUT=$1
ARTIFACT=$2
shift 2

# macOS runners have shasum; ubuntu/windows (Git Bash) have sha256sum. Both
# print "<hex>  <path>", so directory hashes match across runners.
if command -v sha256sum >/dev/null 2>&1; then SHACMD=(sha256sum); else SHACMD=(shasum -a 256); fi

if [ -d "$ARTIFACT" ]; then
  SHA=$(find "$ARTIFACT" -type f -print0 | sort -z | xargs -0 "${SHACMD[@]}" | "${SHACMD[@]}" | cut -d' ' -f1)
elif [ -f "$ARTIFACT" ]; then
  SHA=$("${SHACMD[@]}" "$ARTIFACT" | cut -d' ' -f1)
else
  echo "::error::artifact $ARTIFACT does not exist" >&2
  exit 1
fi

args=(--arg artifactSha256 "$SHA")
# jq variables, not shell ones: single quotes are intended.
# shellcheck disable=SC2016
filter='{artifactSha256: $artifactSha256}'
if command -v flutter >/dev/null 2>&1; then
  FV=$(flutter --version --machine 2>/dev/null | jq -r '.frameworkVersion // empty' || true)
  if [ -n "$FV" ]; then
    args+=(--arg flutterVersion "$FV")
    filter="$filter + {flutterVersion: \$flutterVersion}"
  fi
fi
i=0
for kv in "$@"; do
  i=$((i + 1))
  if [[ "$kv" == *:=* ]]; then
    args+=(--arg "k$i" "${kv%%:=*}" --argjson "v$i" "${kv#*:=}")
  elif [[ "$kv" == *=* ]]; then
    args+=(--arg "k$i" "${kv%%=*}" --arg "v$i" "${kv#*=}")
  else
    echo "::error::bad manifest field '$kv' (key=value or key:=json)" >&2
    exit 2
  fi
  filter="$filter + {(\$k$i): \$v$i}"
done
jq -n "${args[@]}" "$filter" >"$OUT"
cat "$OUT"
