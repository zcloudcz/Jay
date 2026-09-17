#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore-verify.sh — prove a backup is restorable, without touching prod (I02)
# ---------------------------------------------------------------------------
# Decrypts the given (or newest) backup, restores it into a throw-away database,
# compares it with the live database and drops it again. A backup that was
# never restored is only a hope; this is the evidence for RPO/RTO.
#
# Safety rails:
# - The target name is fixed and must differ from the source; the script
#   refuses to run otherwise. pg_restore gets an explicit --dbname and is never
#   called with --clean against anything but the scratch database.
# - Needs a role allowed to CREATE DATABASE (run as the postgres superuser or a
#   dedicated restore role) — NOT the application account.
# - Output contains only counts and migration ids, never row contents.
#
# Usage:
#   AGE_KEY=/secure/calltype-backup.key ./restore-verify.sh [backup-file]
# ---------------------------------------------------------------------------
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5544}"
SOURCE_DB="${SOURCE_DB:-calltype_prod}"
TARGET_DB="calltype_restore_verify"
RESTORE_USER="${RESTORE_USER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/calltype}"
: "${AGE_KEY:?Set AGE_KEY to the path of the operator age private key}"

[ "$TARGET_DB" != "$SOURCE_DB" ] || { echo "refusing: target equals source" >&2; exit 2; }

backup="${1:-$(ls -1t "$BACKUP_DIR"/calltype_*.dump.age | head -n1)}"
[ -f "$backup" ] || { echo "no backup file found" >&2; exit 2; }

psql_admin() { psql -h "$PGHOST" -p "$PGPORT" -U "$RESTORE_USER" -v ON_ERROR_STOP=1 -At "$@"; }

work="$(mktemp -d)"; umask 077
cleanup() { rm -rf "$work"; psql_admin -d postgres -c "DROP DATABASE IF EXISTS $TARGET_DB" >/dev/null || true; }
trap cleanup EXIT

echo "backup:   $backup ($(stat -c %s "$backup") bytes)"
start=$(date +%s)
age -d -i "$AGE_KEY" -o "$work/dump" "$backup"

psql_admin -d postgres -c "DROP DATABASE IF EXISTS $TARGET_DB" -c "CREATE DATABASE $TARGET_DB" >/dev/null
pg_restore -h "$PGHOST" -p "$PGPORT" -U "$RESTORE_USER" --dbname="$TARGET_DB" \
  --exit-on-error --no-owner --no-privileges "$work/dump"
echo "restore:  OK in $(( $(date +%s) - start ))s"

# Compare applied EF migrations and per-table row counts. The live DB may have
# MORE rows than the backup (it kept running) but never fewer tables or a
# different migration history for the same point in time.
q_migr='SELECT string_agg("MigrationId", E"\n" ORDER BY "MigrationId") FROM "__EFMigrationsHistory"'
q_tabs="SELECT string_agg(format('%s=%s', relname, n_live_tup), E'\n' ORDER BY relname) FROM pg_stat_user_tables"

psql_admin -d "$TARGET_DB" -c 'ANALYZE' >/dev/null
echo "--- migrations (restored)"; psql_admin -d "$TARGET_DB" -c "$q_migr"
echo "--- migrations (live)";     psql_admin -d "$SOURCE_DB" -c "$q_migr"
echo "--- row counts (restored)"; psql_admin -d "$TARGET_DB" -c "$q_tabs"
echo "--- row counts (live, estimate)"; psql_admin -d "$SOURCE_DB" -c "$q_tabs"

if [ "$(psql_admin -d "$TARGET_DB" -c "$q_migr")" = "$(psql_admin -d "$SOURCE_DB" -c "$q_migr")" ]; then
  echo "RESULT: PASS — restorable, migration history matches (total $(( $(date +%s) - start ))s = measured RTO floor)"
else
  echo "RESULT: CHECK — migration history differs (expected only if a deploy happened after this backup)"
fi
