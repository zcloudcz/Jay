#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-api-url.sh <url> — refuse an unusable production API URL (R01, P9)
# ---------------------------------------------------------------------------
# The API URL is compiled into every distributed client. An empty, plain-HTTP
# or loopback value would ship a binary that can never reach the server, so
# every release job (deploy.yml build-web, _release-*.yml) checks it before
# spending runner minutes. Moved here from deploy.yml so all release
# workflows apply the same rule.
# ---------------------------------------------------------------------------
set -euo pipefail

URL=${1:-}
if [ -z "$URL" ]; then
  echo "::error::CALLTYPE_API_BASE_URL repository variable is empty. Set it to the deployed API's HTTPS URL before releasing."
  exit 1
fi
case "$URL" in
  https://*) ;;
  *)
    echo "::error::CALLTYPE_API_BASE_URL must be HTTPS, got: $URL"
    exit 1
    ;;
esac
case "$URL" in
  *localhost* | *127.0.0.1* | *0.0.0.0* | *::1*)
    echo "::error::CALLTYPE_API_BASE_URL points at a loopback address, not a public endpoint: $URL"
    exit 1
    ;;
esac
echo "API URL ok: $URL"
