#!/usr/bin/env bash
# First-time setup of jay_archiver on the owner's Linux server (variant A).
# Run next to the copied infra/archiver folder:
#
#   scp -r infra/archiver docs/ops/archiver-beta.sh <server>:~/jay-archiver/
#   ssh <server> 'cd ~/jay-archiver && bash archiver-beta.sh'
#
# Idempotent: keeps an existing .env (and therefore BOT_STORE_KEY) — losing
# that key means a new auditor device, see docs/ops/archiver-runbook.md.
set -euo pipefail
cd "$(dirname "$0")/archiver"

API_URL="${JAY_API_URL:-https://calltype-beta-zahy.azurewebsites.net}"

if [[ -f .env ]]; then
  echo "== .env exists, keeping it (BOT_STORE_KEY must never be regenerated)."
else
  read -rp "Organization id (GUID from the app: Organizace → detail): " ORG_ID
  KEY="$(openssl rand -base64 32)"
  umask 077
  cat > .env <<EOF
JAY_API_URL=$API_URL
JAY_ORG_ID=$ORG_ID
BOT_STORE_KEY=$KEY
EOF
  echo "== .env written (mode 600). Back up BOT_STORE_KEY into your password manager NOW:"
  echo "   grep BOT_STORE_KEY .env"
fi

echo "== Building image"
docker compose build

if docker volume inspect archiver-org1-state >/dev/null 2>&1 && \
   docker run --rm -v archiver-org1-state:/data alpine test -e /data/archiver; then
  echo "== State volume already provisioned, skipping provision."
else
  echo "== Provisioning auditor device (one time)"
  docker compose run --rm archiver-org1 provision --state /data/archiver
  echo
  echo ">>> Paste the deviceId above into the app: Organizace → Zařízení auditora."
  read -rp "Done? [Enter to start the archiver] "
fi

docker compose up -d
echo "== Running. Logs: docker compose logs -f archiver-org1"
echo "== Liveness: GET /orgs/{id}/audit/records/count → pendingForAuditor should hover near 0."
