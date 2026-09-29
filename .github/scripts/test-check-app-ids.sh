#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-check-app-ids.sh — proves check-app-ids.sh catches a broken identifier
# ---------------------------------------------------------------------------
# A guard that never fails is worse than none, so ci.yml `platform-config`
# runs the check against the real tree (must pass) AND against deliberately
# broken copies in mktemp -d (each must fail, naming the file).
# ---------------------------------------------------------------------------
# `cond && ok || bad` is an assertion one-liner; ok/bad always return 0.
# shellcheck disable=SC2015
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$HERE/check-app-ids.sh"
APP=$(cd "$HERE/../../src/client/calltype" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failures=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { failures=$((failures + 1)); echo "FAIL - $1"; }

bash "$CHECK" >/dev/null && ok "real tree passes" || bad "real tree fails: $(bash "$CHECK" 2>&1 | tail -n 5)"

fresh() { # copy of the platform config files only (no build outputs)
  rm -rf "$TMP/app"
  mkdir -p "$TMP/app"
  for d in android ios macos windows; do cp -R "$APP/$d" "$TMP/app/$d"; done
  cp "$APP/pubspec.yaml" "$TMP/app/pubspec.yaml"
}
expect_fail() { # <name> <expected text in output>
  local o
  if o=$(JAY_APP_DIR="$TMP/app" bash "$CHECK" 2>&1); then
    bad "$1: passed but should fail"
  else
    printf '%s' "$o" | grep -q -- "$2" && ok "$1" || bad "$1: unexpected output: $o"
  fi
}

fresh
JAY_APP_DIR="$TMP/app" bash "$CHECK" >/dev/null && ok "unmodified copy passes" || bad "unmodified copy fails"

fresh
sed -i.bak 's/applicationId = "cz.zcloud.jay"/applicationId = "com.example.calltype"/' "$TMP/app/android/app/build.gradle.kts"
expect_fail "android applicationId" "applicationId must be"

fresh
sed -i.bak '1,/PRODUCT_BUNDLE_IDENTIFIER = cz.zcloud.jay;/ s/PRODUCT_BUNDLE_IDENTIFIER = cz.zcloud.jay;/PRODUCT_BUNDLE_IDENTIFIER = cz.zcloud.other;/' \
  "$TMP/app/ios/Runner.xcodeproj/project.pbxproj"
expect_fail "iOS bundle id" "is not cz.zcloud.jay"

fresh
sed -i.bak 's/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = com.calltype.calltype/' "$TMP/app/macos/Runner/Configs/AppInfo.xcconfig"
expect_fail "macOS bundle id" "AppInfo.xcconfig"

fresh
printf '\nmsix_config:\n  display_name: Jay\n  identity_name: cz.zcloud.other\n' >>"$TMP/app/pubspec.yaml"
expect_fail "msix identity_name" "identity_name must be"

fresh
echo '// com.example.calltype' >>"$TMP/app/windows/runner/main.cpp"
expect_fail "template leftover in windows/" "template identifier left over"

echo "# $pass passed, $failures failed"
[ "$failures" -eq 0 ]
