#!/usr/bin/env bash
# N06 (docs/superpowers/plans/2026-09-18-nis2-auditovatelnost.md): fail CI on a
# known vulnerability in a .NET project. `dotnet list package --vulnerable`
# always exits 0, even when it finds something (this is documented .NET
# behavior, not a bug) — so this script does the failing itself.
#
# Usage: check-dotnet-vulnerable.sh <project-or-solution-path> [...]
# Exits non-zero if any argument has a known vulnerable package that is not
# covered by a dated allow-list entry in infra/ci/dotnet-vuln-allowlist.txt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="$SCRIPT_DIR/dotnet-vuln-allowlist.txt"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <project-or-solution-path> [...]" >&2
  exit 2
fi

# GitHub advisory URLs are not localized, unlike the surrounding prose (the
# .NET SDK's own messages come out in whatever locale the runner defaults
# to), so grepping for the advisory link is the one locale-independent way
# to detect a hit.
ADVISORY_PATTERN='github\.com/advisories/(GHSA-[A-Za-z0-9-]+)'

fail=0
for project in "$@"; do
  echo "=== dotnet list package --vulnerable: $project ==="
  output="$(dotnet list "$project" package --vulnerable --include-transitive 2>&1)"
  echo "$output"

  # Collect every advisory id mentioned for this project (dedup: the same
  # advisory can appear once as a restore-time warning and once in the table).
  mapfile -t advisories < <(grep -oE "$ADVISORY_PATTERN" <<<"$output" | sed -E 's#.*/(GHSA-[A-Za-z0-9-]+)#\1#' | sort -u)

  for advisory in "${advisories[@]:-}"; do
    [ -z "$advisory" ] && continue
    if [ -f "$ALLOWLIST" ] && grep -qE "^[^#]*\b${advisory}\b" "$ALLOWLIST"; then
      echo "ALLOWED (see $ALLOWLIST): $advisory in $project"
    else
      echo "::error::Known vulnerability $advisory in $project is not on the allow-list ($ALLOWLIST). Fix within the severity deadline (critical: 7 days, high: 30 days) or add a dated, reasoned exception."
      fail=1
    fi
  done
done

exit "$fail"
