#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-backlog.sh — alert when an organization's auditor stops archiving (O4)
# ---------------------------------------------------------------------------
# Runs ON the database server (cron, every 15 min), next to the archiver
# containers (hosting decision R-O3). Same signal as the API's
# AuditorLivenessService: the age of the oldest un-acked GROUP message queued
# for the organization's auditor device. The API stops the organization's
# business messaging when that age reaches Business:AuditorMaxBacklogAgeSeconds
# (default 24 h); this check warns long before that.
#
# Why SQL on the server and not GET /orgs/{id}/audit/records/count: that
# endpoint needs an organization admin's JWT (short-lived, MFA step-up for
# admin actions) — there is no credential a cron job could hold safely. The
# monitor role (monitor-role.sql) can read four columns and nothing else.
#
# Why only the archiver's own health status in addition: "container running"
# says nothing — a connected archiver can still fail every archive write.
# The queue age is the ground truth; the Docker health is a hint for WHY.
#
# Exit code (Nagios style): 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN (check broken).
# Output: one line per organization, only ids and numbers — never names.
#
# Settings (env):
#   PGHOST/PGPORT         default 127.0.0.1:5544, user calltype_monitor (~/.pgpass)
#   WARN_AGE_SECONDS      default 3600   (1 h: a restart or short outage is fine)
#   CRIT_AGE_SECONDS      default 43200  (12 h: half-way to the 24 h cut-off)
#   ARCHIVER_CONTAINERS   default "jay-archiver-org1" (space separated; "" = skip)
#   ALERT_WEBHOOK_FILE    optional file (0600) with an incoming-webhook URL
#                         (Slack-compatible JSON {"text": ...}). Sent on a
#                         status change and then at most every
#                         ALERT_REPEAT_SECONDS (default 21600 = 6 h), so a
#                         15-minute cron does not flood the channel.
#   STATE_DIR             default /var/lib/calltype-monitor
# Cron:
#   */15 * * * * ALERT_WEBHOOK_FILE=/etc/calltype/alert-webhook.url /opt/calltype/check-backlog.sh >> /var/log/calltype-archiver-check.log 2>&1
# ---------------------------------------------------------------------------
set -uo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5544}"
PGUSER="${PGUSER:-calltype_monitor}"
PROD_DB="${PROD_DB:-calltype_prod}"
AUDIT_DB="${AUDIT_DB:-calltype_audit}"
WARN_AGE_SECONDS="${WARN_AGE_SECONDS:-3600}"
CRIT_AGE_SECONDS="${CRIT_AGE_SECONDS:-43200}"
ARCHIVER_CONTAINERS="${ARCHIVER_CONTAINERS-jay-archiver-org1}"
ALERT_WEBHOOK_FILE="${ALERT_WEBHOOK_FILE:-}"
ALERT_REPEAT_SECONDS="${ALERT_REPEAT_SECONDS:-21600}"
STATE_DIR="${STATE_DIR:-/var/lib/calltype-monitor}"
export PGHOST PGPORT PGUSER

now="$(date -u +%FT%TZ)"
q() { psql -X -At -F ' ' -v ON_ERROR_STOP=1 "$@"; }
# First real error line of a failed psql call (skips WARNING noise).
err() { grep -m1 -iE 'error|fatal|could not' <<< "$1" || head -n1 <<< "$1"; }

status=0   # worst status seen
lines=()
bump() { [ "$1" -gt "$status" ] && status="$1"; }

# 1. Organizations and their auditor device (audit DB).
if ! orgs="$(q -d "$AUDIT_DB" -c 'SELECT "OrganizationId", coalesce("AuditorDeviceId"::text, $$-$$) FROM "Organizations" ORDER BY 1' 2>&1)"; then
  lines+=("UNKNOWN cannot read $AUDIT_DB: $(err "$orgs")"); bump 3
  orgs=""
fi

# 2. Backlog per auditor (prod DB) — one query for all auditors.
auditors="$(awk 'NF == 2 && $2 != "-" {print "\x27" $2 "\x27"}' <<< "$orgs" | paste -sd, -)"
declare -A pending oldest_age
if [ -n "$auditors" ]; then
  if ! backlog="$(q -d "$PROD_DB" -c "SELECT \"RecipientId\", count(*), coalesce(extract(epoch FROM now() - min(\"CreatedAt\"))::bigint, 0)
        FROM \"QueuedMessages\"
       WHERE \"RecipientId\" IN ($auditors) AND \"GroupId\" IS NOT NULL AND \"AcknowledgedAt\" IS NULL
       GROUP BY 1" 2>&1)"; then
    lines+=("UNKNOWN cannot read $PROD_DB: $(err "$backlog")"); bump 3
    backlog=""
  fi
  while read -r dev n age; do
    [ -n "${dev:-}" ] || continue
    pending[$dev]=$n; oldest_age[$dev]=$age
  done <<< "$backlog"
fi

while read -r org dev; do
  [ -n "${org:-}" ] || continue
  if [ "$dev" = "-" ]; then
    # No auditor = the API treats the organization as "auditor dead": its
    # business conversations are blocked until an admin assigns one.
    lines+=("WARN org=$org auditor=none (business messaging blocked until an admin sets the auditor device)"); bump 1
    continue
  fi
  n="${pending[$dev]:-0}"; age="${oldest_age[$dev]:-0}"
  if [ "$age" -ge "$CRIT_AGE_SECONDS" ]; then s=CRIT; bump 2
  elif [ "$age" -ge "$WARN_AGE_SECONDS" ]; then s=WARN; bump 1
  else s=OK; fi
  lines+=("$s org=$org auditor=$dev pending=$n oldest_age=${age}s")
done <<< "$orgs"

# 3. Archiver containers (hint only; never makes the result better).
for c in $ARCHIVER_CONTAINERS; do
  h="$(docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}} restarts={{.RestartCount}}' "$c" 2>/dev/null)" \
    || { lines+=("WARN container=$c missing"); bump 1; continue; }
  case "$h" in
    running/healthy*) lines+=("OK container=$c $h") ;;
    running/starting*) lines+=("OK container=$c $h") ;;
    *) lines+=("WARN container=$c $h"); bump 1 ;;
  esac
done

label=(OK WARN CRIT UNKNOWN)
summary="$now archiver-backlog ${label[$status]}"
printf '%s\n' "$summary" "${lines[@]/#/  }"

# 4. Optional webhook, de-duplicated.
if [ -n "$ALERT_WEBHOOK_FILE" ] && [ -r "$ALERT_WEBHOOK_FILE" ]; then
  mkdir -p "$STATE_DIR"
  last="$(cat "$STATE_DIR/archiver-backlog.state" 2>/dev/null || echo "0 0")"
  last_status="${last%% *}"; last_sent="${last##* }"; t="$(date +%s)"
  if [ "$status" != "$last_status" ] || { [ "$status" -ne 0 ] && [ $((t - last_sent)) -ge "$ALERT_REPEAT_SECONDS" ]; }; then
    text="$(printf '%s\n' "$summary" "${lines[@]}" | grep -v '^OK ' | head -20)"
    body="$(jq -n --arg text "$text" '{text: $text}' 2>/dev/null || printf '{"text":"%s"}' "$summary")"
    printf 'url = "%s"\n' "$(tr -d '\r\n' < "$ALERT_WEBHOOK_FILE")" \
      | curl --config - -sS --fail --max-time 20 -H 'Content-Type: application/json' -d "$body" -o /dev/null \
      && echo "$status $t" > "$STATE_DIR/archiver-backlog.state"
  fi
fi
exit "$status"
