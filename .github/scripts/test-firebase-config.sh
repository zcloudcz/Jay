#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-firebase-config.sh — tests for firebase-config.sh with fake secrets
# ---------------------------------------------------------------------------
# Runs against a scratch app dir (JAY_APP_DIR in mktemp -d), so the committed
# web/firebase-config.js and the git-ignored outputs of the real app are never
# touched. The fake values are obviously fake; no real Firebase project.
# Needs bash, jq, base64, python3 (all on hosted ubuntu/macos runners).
# ---------------------------------------------------------------------------
# `cond && ok || bad` is an assertion one-liner; ok/bad always return 0.
# shellcheck disable=SC2015
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/firebase-config.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failures=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { failures=$((failures + 1)); echo "FAIL - $1"; }

b64() { base64 | tr -d '\n'; }
APP="$TMP/app"
fresh() {
  rm -rf "$APP"
  mkdir -p "$APP/web" "$APP/android/app" "$APP/ios/Runner" "$APP/macos/Runner"
  echo 'self.JAY_FIREBASE_CONFIG = null;' >"$APP/web/firebase-config.js"
}
run() { # <platform>; env passes through
  JAY_APP_DIR="$APP" bash "$SCRIPT" "$1" 2>&1
}
unset FIREBASE_CLIENT_CONFIG_JSON_B64 FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64 FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64

CLIENT=$(
  cat <<'EOF' | b64
{"FIREBASE_PROJECT_ID":"jay-fake","FIREBASE_MESSAGING_SENDER_ID":"123","FIREBASE_STORAGE_BUCKET":"jay-fake.appspot.com",
 "FIREBASE_WEB_API_KEY":"web-key","FIREBASE_WEB_APP_ID":"1:123:web:abc","FIREBASE_WEB_AUTH_DOMAIN":"jay-fake.firebaseapp.com",
 "FIREBASE_WEB_VAPID_KEY":"vapid","FIREBASE_ANDROID_API_KEY":"and-key","FIREBASE_ANDROID_APP_ID":"1:123:android:abc",
 "FIREBASE_APPLE_API_KEY":"apple-key","FIREBASE_IOS_APP_ID":"1:123:ios:abc","FIREBASE_APPLE_BUNDLE_ID":"cz.zcloud.jay",
 "API_BASE_URL":"https://evil.invalid"}
EOF
)
gs_json() { # <package> <project>
  printf '{"project_info":{"project_id":"%s"},"client":[{"client_info":{"android_client_info":{"package_name":"%s"}}}]}' "$2" "$1" | b64
}
plist() { # <bundle id>
  python3 -c 'import plistlib,sys; sys.stdout.buffer.write(plistlib.dumps({"BUNDLE_ID": sys.argv[1], "PROJECT_ID": "jay-fake"}))' "$1" | b64
}

# 1. Nothing configured: {} + warning, committed web file untouched.
fresh
o=$(run web) && [ "$(cat "$APP/build-defines/firebase.json")" = '{}' ] &&
  grep -q 'JAY_FIREBASE_CONFIG = null' "$APP/web/firebase-config.js" &&
  printf '%s' "$o" | grep -q '::warning::Firebase not configured for web' &&
  ok "no secrets: {} defines, web stays null, warning" || bad "no secrets: $o"

# 2. Full web config.
fresh
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$CLIENT run web) &&
  jq -e '.FIREBASE_PROJECT_ID == "jay-fake" and .FIREBASE_WEB_VAPID_KEY == "vapid"' "$APP/build-defines/firebase.json" >/dev/null &&
  ok "web: defines written" || bad "web defines: $o"
jq -e 'has("API_BASE_URL") | not' "$APP/build-defines/firebase.json" >/dev/null &&
  ok "non-FIREBASE_ keys are dropped (cannot override API_BASE_URL)" || bad "API_BASE_URL leaked into defines"
js=$(sed -n 's/^self.JAY_FIREBASE_CONFIG = \(.*\);$/\1/p' "$APP/web/firebase-config.js")
printf '%s' "$js" | jq -e '.apiKey == "web-key" and .projectId == "jay-fake" and .appId == "1:123:web:abc"
  and .messagingSenderId == "123" and .authDomain == "jay-fake.firebaseapp.com" and .storageBucket == "jay-fake.appspot.com"
  and (keys | length) == 6' >/dev/null && ok "web: firebase-config.js has the 6 JS SDK keys" || bad "web js: $js"
if printf '%s' "$o" | grep -q -e 'web-key' -e 'jay-fake'; then bad "log leaks a config value"; else ok "log does not print values"; fi

# 3. Web keys incomplete: defines written, JS stays null.
fresh
PARTIAL=$(printf '{"FIREBASE_PROJECT_ID":"p","FIREBASE_MESSAGING_SENDER_ID":"1","FIREBASE_ANDROID_API_KEY":"k","FIREBASE_ANDROID_APP_ID":"a"}' | b64)
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$PARTIAL run web) && grep -q 'JAY_FIREBASE_CONFIG = null' "$APP/web/firebase-config.js" &&
  ok "web: incomplete web keys keep null" || bad "web partial: $o"

# 4. Android with a matching google-services.json.
fresh
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$CLIENT FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64=$(gs_json cz.zcloud.jay jay-fake) run android) &&
  [ -f "$APP/android/app/google-services.json" ] && ok "android: google-services.json written" || bad "android: $o"

# 5. Android with another app's google-services.json must fail and write nothing.
fresh
o=$(FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64=$(gs_json com.example.calltype jay-fake) run android) &&
  bad "wrong package accepted" ||
  { [ ! -f "$APP/android/app/google-services.json" ] && printf '%s' "$o" | grep -q 'no Android client for cz.zcloud.jay' &&
    ok "android: wrong package name rejected" || bad "wrong package: $o"; }

# 6. Android: google-services.json from another Firebase project.
fresh
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$CLIENT FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64=$(gs_json cz.zcloud.jay other) run android) &&
  bad "project mismatch accepted" || ok "android: project mismatch rejected"

# 7. Broken inputs.
fresh
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64='%%%not-base64' run web) && bad "bad base64 accepted" || ok "bad base64 rejected"
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$(printf '{"FIREBASE_PROJECT_ID":{"x":1}}' | b64) run web) &&
  bad "nested JSON accepted" || ok "nested JSON rejected"
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$(printf '{"FIREBASE_WEB_API_KEY":"k"}' | b64) run web) &&
  bad "missing project id accepted" || ok "missing FIREBASE_PROJECT_ID rejected"
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$(printf '{"FIREBASE_PROJECT_ID":"p","FIREBASE_APPLE_BUNDLE_ID":"com.other"}' | b64) run ios) &&
  bad "foreign bundle id accepted" || ok "foreign FIREBASE_APPLE_BUNDLE_ID rejected"
o=$(run tvos) && bad "unknown platform accepted" || ok "unknown platform rejected"

# 8. Base64 with line breaks (as pasted from `base64` without -w0) is accepted.
fresh
WRAPPED=$(printf '%s' "$CLIENT" | fold -w 60)
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$WRAPPED run android) &&
  jq -e '.FIREBASE_ANDROID_APP_ID == "1:123:android:abc"' "$APP/build-defines/firebase.json" >/dev/null &&
  ok "wrapped base64 accepted" || bad "wrapped base64: $o"

# 9. Apple plist: optional, bundle id checked, lands in the right Runner.
fresh
o=$(FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64=$(plist cz.zcloud.jay) run macos) &&
  [ -f "$APP/macos/Runner/GoogleService-Info.plist" ] && [ ! -f "$APP/ios/Runner/GoogleService-Info.plist" ] &&
  ok "macos: plist written to macos/Runner" || bad "macos plist: $o"
fresh
o=$(FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64=$(plist com.example.calltype) run ios) &&
  bad "foreign plist accepted" || { [ ! -f "$APP/ios/Runner/GoogleService-Info.plist" ] && ok "ios: foreign plist rejected" || bad "ios plist written"; }

# 10. Windows/Linux never carry the identifiers.
fresh
o=$(FIREBASE_CLIENT_CONFIG_JSON_B64=$CLIENT run windows) && [ "$(cat "$APP/build-defines/firebase.json")" = '{}' ] &&
  ok "windows: {} even with config" || bad "windows: $o"

echo "# $pass passed, $failures failed"
[ "$failures" -eq 0 ]
