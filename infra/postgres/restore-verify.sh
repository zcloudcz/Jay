#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore-verify.sh — prove a backup SET is restorable, without touching prod
#                     (I02, N05 / O3 in docs/superpowers/plans/2026-09-29-gap-ops.md)
# ---------------------------------------------------------------------------
# For every database in $DATABASES it decrypts the dump + manifest written by
# backup.sh, restores the dump into an EMPTY scratch database
# (<db>_restore_verify, optionally on a different, empty instance), counts
# every table exactly and compares the counts with the manifest taken from the
# dump's own snapshot. A backup that was never restored is only a hope; this
# is the evidence for RPO/RTO (docs/ops/postgres-restore.md).
#
# PASS requires, per database: pg_restore without a single error, the same set
# of tables as the manifest, and an identical row count in every table.
#
# Safety rails:
# - Target names are derived (<db>_restore_verify), must differ from every
#   source name, and the script refuses to run otherwise. pg_restore gets an
#   explicit --dbname and never --clean; the only thing ever dropped is a
#   database whose name ends in _restore_verify.
# - Needs a role allowed to CREATE DATABASE on the target (the postgres
#   superuser, or a dedicated restore role on a scratch instance) — NOT an
#   application account.
# - Output contains only counts, table names and migration ids, never row
#   contents.
#
# Usage:
#   AGE_KEY=/secure/calltype-backup.key ./restore-verify.sh [stamp]
#     stamp   e.g. 20260929T031500Z; default = newest stamp for which EVERY
#             database in $DATABASES has a dump and a manifest
#   RESTORE_HOST/RESTORE_PORT  target instance (default: PGHOST/PGPORT). Point
#             it at an empty scratch instance for a true "restore into an empty
#             server" drill.
#   KEEP_RESTORED=1  leave the scratch databases for inspection (drop them by
#             hand afterwards — they contain production metadata).
# ---------------------------------------------------------------------------
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5544}"
RESTORE_HOST="${RESTORE_HOST:-$PGHOST}"
RESTORE_PORT="${RESTORE_PORT:-$PGPORT}"
RESTORE_USER="${RESTORE_USER:-postgres}"
DATABASES="${DATABASES:-calltype_prod calltype_audit}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/calltype}"
KEEP_RESTORED="${KEEP_RESTORED:-0}"
: "${AGE_KEY:?Set AGE_KEY to the path of the operator age private key}"

for db in $DATABASES; do
  for other in $DATABASES; do
    [ "${db}_restore_verify" != "$other" ] || { echo "refusing: target ${db}_restore_verify equals a source" >&2; exit 2; }
  done
done

# Newest stamp with a complete set (dump + manifest for every database).
complete_stamp() {
  local s db ok
  for s in $(ls -1 "$BACKUP_DIR" | sed -n 's/^.*_\([0-9]\{8\}T[0-9]\{6\}Z\)\.dump\.age$/\1/p' | sort -ru); do
    ok=1
    for db in $DATABASES; do
      [ -f "$BACKUP_DIR/${db}_${s}.dump.age" ] && [ -f "$BACKUP_DIR/${db}_${s}.manifest.age" ] || ok=0
    done
    [ "$ok" = 1 ] && { echo "$s"; return 0; }
  done
  return 1
}
stamp="${1:-$(complete_stamp || true)}"
[ -n "$stamp" ] || { echo "no complete backup set in $BACKUP_DIR" >&2; exit 2; }

psql_target() { psql -X -h "$RESTORE_HOST" -p "$RESTORE_PORT" -U "$RESTORE_USER" -v ON_ERROR_STOP=1 -At "$@"; }

umask 077
work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
  if [ "$KEEP_RESTORED" != 1 ]; then
    for db in $DATABASES; do
      psql_target -d postgres -c "DROP DATABASE IF EXISTS ${db}_restore_verify" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

# Same query shape as backup.sh, so both sides produce identical lines. Fed
# on stdin, not -c: psql's -c cannot mix SQL with the \gexec meta-command.
COUNT_SQL="SELECT format('SELECT %L || '' '' || count(*) FROM %I.%I', 'count ' || n.nspname || '.' || c.relname, n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
 ORDER BY n.nspname, c.relname \\gexec"

echo "backup set: $stamp  target: $RESTORE_HOST:$RESTORE_PORT"
total_start=$(date +%s)
overall=PASS

for db in $DATABASES; do
  target="${db}_restore_verify"
  dump_enc="$BACKUP_DIR/${db}_${stamp}.dump.age"
  man_enc="$BACKUP_DIR/${db}_${stamp}.manifest.age"
  echo "=== $db -> $target"
  if [ ! -f "$dump_enc" ] || [ ! -f "$man_enc" ]; then
    echo "RESULT $db: FAIL — missing $dump_enc or its manifest"; overall=FAIL; continue
  fi
  echo "backup:   $dump_enc ($(stat -c %s "$dump_enc") bytes)"
  start=$(date +%s)

  # age authenticates the ciphertext: a truncated or tampered file fails here.
  if ! age -d -i "$AGE_KEY" -o "$work/$db.dump" "$dump_enc" \
     || ! age -d -i "$AGE_KEY" -o "$work/$db.manifest" "$man_enc"; then
    echo "RESULT $db: FAIL — cannot decrypt (wrong key or damaged file)"; overall=FAIL; continue
  fi
  t_decrypt=$(( $(date +%s) - start ))

  psql_target -d postgres -c "DROP DATABASE IF EXISTS $target" -c "CREATE DATABASE $target" >/dev/null
  # --single-transaction: a restore either lands completely or not at all;
  # --exit-on-error: the first error is fatal, never "restored with warnings".
  if ! pg_restore -h "$RESTORE_HOST" -p "$RESTORE_PORT" -U "$RESTORE_USER" --dbname="$target" \
       --exit-on-error --single-transaction --no-owner --no-privileges "$work/$db.dump"; then
    echo "RESULT $db: FAIL — pg_restore reported an error"; overall=FAIL; continue
  fi
  t_restore=$(( $(date +%s) - start ))

  grep '^count ' "$work/$db.manifest" | sort > "$work/$db.expected"
  psql_target -q -d "$target" <<< "$COUNT_SQL" | sort > "$work/$db.actual"
  t_total=$(( $(date +%s) - start ))

  tables=$(wc -l < "$work/$db.expected")
  rows=$(awk '{s+=$3} END {print s+0}' "$work/$db.expected")
  echo "manifest: $(grep -E '^(server_version|last_migration) ' "$work/$db.manifest" | tr '\n' ' ')"
  echo "restored: last_migration $(psql_target -d "$target" -c "SELECT coalesce(max(\"MigrationId\"), '-') FROM \"__EFMigrationsHistory\"" 2>/dev/null || echo '-')"
  if diff -u "$work/$db.expected" "$work/$db.actual" > "$work/$db.diff"; then
    echo "counts:   $tables tables, $rows rows — identical to the manifest"
    echo "timing:   decrypt ${t_decrypt}s, decrypt+restore ${t_restore}s, total ${t_total}s"
    echo "RESULT $db: PASS"
  else
    echo "counts:   DIFFERENT from the manifest (- expected, + restored):"
    grep '^[-+]count' "$work/$db.diff" || true
    echo "RESULT $db: FAIL"
    overall=FAIL
  fi
done

total=$(( $(date +%s) - total_start ))
echo "=== RESULT: $overall — set $stamp, $(echo $DATABASES | wc -w) database(s), ${total}s total (= measured RTO floor for the data restore, excluding provisioning and DNS/app reconfiguration)"
[ "$overall" = PASS ]
