#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# backup.sh — daily encrypted PostgreSQL backup of BOTH CallType databases
#             (I02, N05 / O3 in docs/superpowers/plans/2026-09-29-gap-ops.md)
# ---------------------------------------------------------------------------
# Runs ON the database server (cron). For every database in $DATABASES
# (default: calltype_prod, then calltype_audit) it produces
#   <db>_<stamp>.dump.age      encrypted pg_dump custom-format archive
#   <db>_<stamp>.manifest.age  encrypted exact row counts taken from the SAME
#                              snapshot as the dump
# keeps the newest $KEEP sets per database, optionally copies them off the box
# and fails loudly (non-zero exit, FAIL line) so cron mail / monitoring sees it.
#
# Why these choices:
# - pg_dump --format=custom: restorable selectively with pg_restore, compressed.
# - Exact row counts from the dump's own snapshot (pg_export_snapshot +
#   pg_dump --snapshot): restore-verify.sh can then demand an EXACT match per
#   table. Comparing against the live database instead can never be exact —
#   it keeps changing (queued messages get delivered and deleted) — and an
#   inexact check is how a half-restored table slips through.
# - Password comes from ~/.pgpass (0600), never from argv/env — argv is visible
#   in `ps`, shell history and cron logs.
# - Default login is calltype_backup, a read-only role (backup-role.sql,
#   pg_read_all_data). Neither application role can read everything: the
#   audit app role is INSERT/SELECT-only by design and must stay that way,
#   and the ops role that can change the audit schema must not sit in a cron
#   job's .pgpass.
# - Encrypted with a PUBLIC age key: the server can create backups but cannot
#   read them. The private key lives with the operator, off this box. A dump
#   holds metadata (who talks to whom, push tokens, account e-mails, password
#   hashes, the business archive's metadata) even though message bodies are
#   E2E-encrypted. The manifest is encrypted too: table sizes are business
#   information (number of accounts, organizations).
# - Written to a temp name and renamed, so a crashed run never leaves a file
#   that looks like a valid backup.
# - One database failing does not skip the other one — both are attempted,
#   the run as a whole fails. A partial backup is still better than none.
# - calltype_prod is dumped BEFORE calltype_audit: the audit database only
#   grows, so the later audit snapshot is a superset of every organization
#   the earlier prod snapshot can reference. Two databases can never share
#   one snapshot; this ordering is the closest safe approximation.
# - Off-box copy: a backup on the same disk as the database does not survive
#   the loss of the server, so RPO 24 h needs a second location. Two
#   pluggable targets (NIS2 decision 8: not Azure-only):
#     OFFSITE_DIR             a mounted directory on another disk/host
#     OFFSITE_AZURE_SAS_FILE  a file (0600) holding a container SAS URL with
#                             ONLY the "c" (create) permission. Create-only
#                             means this server can add backups but cannot
#                             read, overwrite or delete existing ones — a
#                             compromised DB server cannot destroy the
#                             off-site history. The URL is passed to curl on
#                             stdin (--config -), never in argv.
#
# One-time setup (docs/ops/postgres-restore.md §4):
#   apt install age curl postgresql-client-<server major>
#   psql -U postgres -f infra/postgres/backup-role.sql     # read-only role
#   echo '127.0.0.1:5544:*:calltype_backup:<password>' >> ~/.pgpass && chmod 600 ~/.pgpass
#   age-keygen -o calltype-backup.key        # on the OPERATOR machine, keep private
#   # copy only the "public key: age1..." line into AGE_RECIPIENT
# Cron (daily 03:15 UTC):
#   15 3 * * * AGE_RECIPIENT=age1... OFFSITE_AZURE_SAS_FILE=/etc/calltype/backup-sas.url /opt/calltype/backup.sh >> /var/log/calltype-backup.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5544}"
PGUSER="${PGUSER:-calltype_backup}"
DATABASES="${DATABASES:-calltype_prod calltype_audit}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/calltype}"   # ideally a different disk/host mount than the DB
KEEP="${KEEP:-7}"                                   # local sets kept PER DATABASE
OFFSITE_DIR="${OFFSITE_DIR:-}"
OFFSITE_KEEP="${OFFSITE_KEEP:-35}"                  # only for OFFSITE_DIR; Blob uses a lifecycle rule
OFFSITE_AZURE_SAS_FILE="${OFFSITE_AZURE_SAS_FILE:-}"
: "${AGE_RECIPIENT:?Set AGE_RECIPIENT to the operator age public key (age1...)}"

export PGHOST PGPORT PGUSER
umask 077
mkdir -p "$BACKUP_DIR"
# Fail fast on a mistyped key instead of after the first multi-minute dump.
age -r "$AGE_RECIPIENT" -o /dev/null < /dev/null \
  || { echo "$(date -u +%FT%TZ) FAIL AGE_RECIPIENT is not a valid age public key" >&2; exit 2; }
[ -z "$OFFSITE_AZURE_SAS_FILE" ] || [ -r "$OFFSITE_AZURE_SAS_FILE" ] \
  || { echo "$(date -u +%FT%TZ) FAIL OFFSITE_AZURE_SAS_FILE is not readable" >&2; exit 2; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"   # one stamp per run = one restorable SET
log() { echo "$(date -u +%FT%TZ) $*"; }

# Exact row counts of every ordinary table (partitions included, partitioned
# parents excluded so nothing is counted twice), one "count <table> <n>" line
# each. Executed inside the snapshot transaction below.
COUNT_SQL="SELECT format('SELECT %L || '' '' || count(*) FROM %I.%I', 'count ' || n.nspname || '.' || c.relname, n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
 ORDER BY n.nspname, c.relname \\gexec"

# Uploads one file to the Azure container named by the SAS URL in
# $OFFSITE_AZURE_SAS_FILE ("https://<acct>.blob.core.windows.net/<container>?sv=...").
upload_azure() {
  local file="$1" base url
  base="$(basename "$file")"
  url="$(tr -d '\r\n' < "$OFFSITE_AZURE_SAS_FILE")"
  # Insert the blob name between the container path and the SAS query.
  url="${url%%\?*}/${base}?${url#*\?}"
  # If-None-Match: * — never overwrite a blob of the same name (the SAS has no
  # write permission anyway; this makes the intent explicit and portable).
  printf 'url = "%s"\n' "$url" | curl --config - --silent --show-error --fail \
    --retry 3 --max-time 3600 -X PUT \
    -H 'x-ms-blob-type: BlockBlob' -H 'x-ms-version: 2021-08-06' -H 'If-None-Match: *' \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$file" --output /dev/null
}

copy_offsite() {
  local f
  for f in "$@"; do
    if [ -n "$OFFSITE_DIR" ]; then
      mkdir -p "$OFFSITE_DIR"
      cp "$f" "$OFFSITE_DIR/.$(basename "$f").partial"
      mv "$OFFSITE_DIR/.$(basename "$f").partial" "$OFFSITE_DIR/$(basename "$f")"
    fi
    if [ -n "$OFFSITE_AZURE_SAS_FILE" ]; then
      upload_azure "$f"
    fi
  done
}

backup_db() {
  local db="$1" dump man tmp_dump tmp_man snap line start size
  dump="$BACKUP_DIR/${db}_${stamp}.dump.age"
  man="$BACKUP_DIR/${db}_${stamp}.manifest.age"
  tmp_dump="$dump.partial"; tmp_man="$man.partial"
  start=$(date +%s)

  # Hold a REPEATABLE READ transaction open for the whole dump: its snapshot
  # is exported to pg_dump and used for the row counts, so both see exactly
  # the same data.
  coproc SNAP { psql -X -q -At -v ON_ERROR_STOP=1 -d "$db" 2>&1; }
  local to_psql="${SNAP[1]}" from_psql="${SNAP[0]}" pid="$SNAP_PID"
  printf '%s\n' "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;" "SELECT pg_export_snapshot();" >&"$to_psql"
  if ! read -r -t 60 snap <&"$from_psql" || [[ ! "$snap" =~ ^[0-9A-F-]+$ ]]; then
    log "FAIL $db could not export a snapshot: ${snap:-<no answer>}" >&2
    kill "$pid" 2>/dev/null || true
    return 1
  fi

  {
    echo "format=calltype-backup-manifest-v1"
    echo "database=$db"
    echo "stamp=$stamp"
    echo "snapshot=$snap"
  } > "$BACKUP_DIR/.${db}.manifest.plain"
  printf '%s\n' "SELECT 'server_version ' || current_setting('server_version');" \
    "SELECT 'SELECT ''last_migration '' || coalesce(max(\"MigrationId\"), ''-'') FROM \"__EFMigrationsHistory\"' WHERE to_regclass('public.\"__EFMigrationsHistory\"') IS NOT NULL \\gexec" \
    "$COUNT_SQL" '\echo __END_OF_COUNTS__' >&"$to_psql"
  while read -r -t 600 line <&"$from_psql"; do
    [ "$line" = "__END_OF_COUNTS__" ] && break
    case "$line" in
      count\ *|server_version\ *|last_migration\ *) echo "$line" >> "$BACKUP_DIR/.${db}.manifest.plain" ;;
      *) log "FAIL $db row count query: $line" >&2; kill "$pid" 2>/dev/null || true
         rm -f "$BACKUP_DIR/.${db}.manifest.plain"; return 1 ;;
    esac
  done
  if [ "$line" != "__END_OF_COUNTS__" ]; then
    log "FAIL $db row counts timed out" >&2; kill "$pid" 2>/dev/null || true
    rm -f "$BACKUP_DIR/.${db}.manifest.plain"; return 1
  fi

  # --no-owner/--no-privileges: the restore target uses different roles.
  if ! pg_dump --format=custom --no-owner --no-privileges --snapshot="$snap" --dbname="$db" \
        | age -r "$AGE_RECIPIENT" -o "$tmp_dump"; then
    log "FAIL $db pg_dump/age failed" >&2
    kill "$pid" 2>/dev/null || true
    rm -f "$tmp_dump" "$BACKUP_DIR/.${db}.manifest.plain"; return 1
  fi
  printf '%s\n' "COMMIT;" '\q' >&"$to_psql"
  wait "$pid" 2>/dev/null || true

  age -r "$AGE_RECIPIENT" -o "$tmp_man" "$BACKUP_DIR/.${db}.manifest.plain"
  rm -f "$BACKUP_DIR/.${db}.manifest.plain"

  size=$(stat -c %s "$tmp_dump")
  # An empty/near-empty file means pg_dump produced nothing useful.
  if [ "$size" -lt 1024 ]; then
    log "FAIL $db backup too small ($size bytes)" >&2
    rm -f "$tmp_dump" "$tmp_man"; return 1
  fi
  mv "$tmp_man" "$man"
  mv "$tmp_dump" "$dump"

  if ! copy_offsite "$dump" "$man"; then
    log "FAIL $db off-site copy failed (local copy kept: $dump)" >&2
    return 1
  fi

  # Rotation per database: keep the newest $KEEP complete sets.
  ls -1t "$BACKUP_DIR/${db}"_*.dump.age | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -f "$old" "${old%.dump.age}.manifest.age"
  done
  if [ -n "$OFFSITE_DIR" ]; then
    ls -1t "$OFFSITE_DIR/${db}"_*.dump.age 2>/dev/null | tail -n +$((OFFSITE_KEEP + 1)) | while read -r old; do
      rm -f "$old" "${old%.dump.age}.manifest.age"
    done
  fi

  log "OK $dump size=${size}B duration=$(( $(date +%s) - start ))s kept=$KEEP offsite=$([ -n "$OFFSITE_DIR$OFFSITE_AZURE_SAS_FILE" ] && echo yes || echo no)"
}

failed=0
for db in $DATABASES; do
  backup_db "$db" || failed=1
done
rm -f "$BACKUP_DIR"/*.partial "$BACKUP_DIR"/.*.manifest.plain 2>/dev/null || true

if [ "$failed" -ne 0 ]; then
  log "FAIL backup set $stamp incomplete" >&2
  exit 1
fi
# Heartbeat for monitoring (docs/ops/beta-operations.md: alert when older
# than 26 h). Written only when EVERY database succeeded.
echo "$stamp $DATABASES" > "$BACKUP_DIR/last-success"
log "OK backup set $stamp complete: $DATABASES"
