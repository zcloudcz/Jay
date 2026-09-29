#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-app-ids.sh — one application identifier on every platform (P1/P9)
# ---------------------------------------------------------------------------
# cz.zcloud.jay is immutable after the first Play / App Store upload, and
# Firebase app registrations, assetlinks.json and the AASA file key on it.
# A template default (com.example.*, com.calltype.*) sneaking back in via
# `flutter create` or a merge would silently produce a different app, so CI
# (ci.yml `platform-config`) fails on it, naming the file.
#
# Usage: check-app-ids.sh            (repo root or anywhere inside the repo)
# Env:   JAY_APP_DIR  app directory to check (default src/client/calltype)
# ---------------------------------------------------------------------------
set -euo pipefail

APP_ID=cz.zcloud.jay
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
APP=${JAY_APP_DIR:-$ROOT/src/client/calltype}
errors=0
err() {
  echo "::error file=$1::$2"
  errors=$((errors + 1))
}

# Android: namespace (Kotlin package / R class) and applicationId (store id).
f="$APP/android/app/build.gradle.kts"
if [ -f "$f" ]; then
  grep -Eq "^[[:space:]]*namespace[[:space:]]*=[[:space:]]*\"$APP_ID\"" "$f" || err "$f" "namespace must be \"$APP_ID\""
  grep -Eq "^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*\"$APP_ID\"" "$f" || err "$f" "applicationId must be \"$APP_ID\""
else
  err "$f" "missing"
fi
# Kotlin sources must live in the app's package (stream C may add sub-packages).
if [ -d "$APP/android/app/src/main/kotlin" ]; then
  while IFS= read -r kt; do
    grep -Eq "^package $APP_ID(\.|$)" "$kt" || err "$kt" "Kotlin package must be $APP_ID or below"
  done < <(find "$APP/android/app/src/main/kotlin" -name '*.kt')
fi

# iOS: every non-test target uses the id; tests use <id>.RunnerTests.
f="$APP/ios/Runner.xcodeproj/project.pbxproj"
if [ -f "$f" ]; then
  n=0
  while IFS= read -r id; do
    n=$((n + 1))
    case "$id" in
      "$APP_ID" | "$APP_ID.RunnerTests") ;;
      *) err "$f" "PRODUCT_BUNDLE_IDENTIFIER '$id' is not $APP_ID" ;;
    esac
  done < <(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;.*/\1/p' "$f")
  [ "$n" -gt 0 ] || err "$f" "no PRODUCT_BUNDLE_IDENTIFIER found"
  # Push and universal links silently break when a Runner configuration
  # (Debug/Release/Profile) loses its entitlements file.
  e=$(grep -c 'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;' "$f" || true)
  [ "$e" -eq 3 ] || err "$f" "expected CODE_SIGN_ENTITLEMENTS in the 3 Runner configurations, found $e"
  [ -f "$APP/ios/Runner/Runner.entitlements" ] || err "$APP/ios/Runner/Runner.entitlements" "missing"
  # The team is passed at build time (APPLE_TEAM_ID); a committed one would
  # break `--no-codesign` builds for everyone else and leak into forks.
  if grep -q 'DEVELOPMENT_TEAM = [A-Z0-9]' "$f"; then err "$f" "DEVELOPMENT_TEAM must not be committed"; fi
else
  err "$f" "missing"
fi

# macOS: the bundle id lives in the xcconfig, not the pbxproj.
f="$APP/macos/Runner/Configs/AppInfo.xcconfig"
if [ -f "$f" ]; then
  grep -Eq "^PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*${APP_ID}[[:space:]]*\$" "$f" || err "$f" "PRODUCT_BUNDLE_IDENTIFIER must be $APP_ID"
else
  err "$f" "missing"
fi

# Linux (P8, may not exist yet).
f="$APP/linux/CMakeLists.txt"
if [ -f "$f" ]; then
  grep -Eq "^set\(APPLICATION_ID \"$APP_ID\"\)" "$f" || err "$f" "APPLICATION_ID must be \"$APP_ID\""
fi

# Windows MSIX identity for the direct channel (P7, may not exist yet). The
# Store identity comes from Partner Center at build time, not from here.
f="$APP/pubspec.yaml"
if grep -Eq '^msix_config:' "$f"; then
  id=$(sed -nE '/^msix_config:/,/^[^[:space:]#]/ s/^[[:space:]]+identity_name:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$f" | head -n 1)
  [ "$id" = "$APP_ID" ] || err "$f" "msix_config.identity_name must be $APP_ID, got '$id'"
fi

# Template leftovers anywhere in the platform folders.
dirs=()
for d in android ios macos windows linux; do [ -d "$APP/$d" ] && dirs+=("$APP/$d"); done
if [ ${#dirs[@]} -gt 0 ]; then
  while IFS= read -r hit; do
    err "${hit%%:*}" "template identifier left over: ${hit#*:}"
  done < <(grep -rInE 'com\.example|com\.calltype' \
    --exclude-dir=build --exclude-dir=.gradle --exclude-dir=Pods --exclude-dir=ephemeral \
    --exclude-dir=.symlinks --exclude-dir=.dart_tool "${dirs[@]}" || true)
fi

if [ "$errors" -gt 0 ]; then
  echo "check-app-ids: $errors problem(s)"
  exit 1
fi
echo "check-app-ids: $APP_ID everywhere"
