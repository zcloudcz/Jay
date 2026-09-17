#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# backup.sh — daily encrypted PostgreSQL backup for the CallType beta (I02)
# ---------------------------------------------------------------------------
# Runs ON the database server (cron). Produces an encrypted custom-format dump,
# keeps the newest $KEEP files and fails loudly so cron mail / monitoring sees it.
#
# Why these choices:
# - pg_dump --format=custom: restorable selectively with pg_restore, compressed.
# - Password comes from ~/.pgpass (0600), never from argv/env — argv is visible
#   in `ps`, shell history and cron logs.
# - Encrypted with a PUBLIC age key: the server can create backups but cannot
#   read them. The private key lives with the operator, off this box. A dump
#   holds metadata (who talks to whom, push tokens, account e-mails, password
#   hashes) even though message bodies are E2E-encrypted.
# - Written to a temp name and renamed, so a crashed run never leaves a file
#   that looks like a valid backup.
#
# One-time setup:
#   apt install age postgresql-client-<server major>
#   echo '127.0.0.1:5544:calltype_prod:calltype_prod:<password>' >> ~/.pgpass && chmod 600 ~/.pgpass
#   age-keygen -o calltype-backup.key        # on the OPERATOR machine, keep private
#   # copy only the "public key: age1..." line into AGE_RECIPIENT below / env
# Cron (daily 03:15 UTC):
#   15 3 * * * AGE_RECIPIENT=age1... /opt/calltype/backup.sh >> /var/log/calltype-backup.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5544}"
PGDATABASE="${PGDATABASE:-calltype_prod}"
PGUSER="${PGUSER:-calltype_prod}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/calltype}"   # ideally a different disk/host mount than the DB
KEEP="${KEEP:-7}"
: "${AGE_RECIPIENT:?Set AGE_RECIPIENT to the operator age public key (age1...)}"

export PGHOST PGPORT PGDATABASE PGUSER
umask 077
mkdir -p "$BACKUP_DIR"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="$BACKUP_DIR/calltype_${stamp}.dump.age"
tmp="$final.partial"
trap 'rm -f "$tmp"' EXIT

start=$(date +%s)
# --no-owner/--no-privileges: the restore target uses different roles.
pg_dump --format=custom --no-owner --no-privileges | age -r "$AGE_RECIPIENT" -o "$tmp"
mv "$tmp" "$final"
trap - EXIT

size=$(stat -c %s "$final")
# An empty/near-empty file means pg_dump produced nothing useful.
if [ "$size" -lt 1024 ]; then
  echo "$(date -u +%FT%TZ) FAIL backup too small ($size bytes): $final" >&2
  exit 1
fi

# Rotation: delete everything except the newest $KEEP successful backups.
ls -1t "$BACKUP_DIR"/calltype_*.dump.age | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$(date -u +%FT%TZ) OK $final size=${size}B duration=$(( $(date +%s) - start ))s kept=$KEEP"
