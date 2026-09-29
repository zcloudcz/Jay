#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# staging-databases.sh — databases and roles for the staging API (N10 / O6)
# ---------------------------------------------------------------------------
# Creates, on the SAME PostgreSQL server as beta (owner decision 2026-09-18):
#   calltype_staging        owned by role calltype_staging (like calltype_prod)
#   calltype_audit_staging  with roles calltype_audit_staging_app / _ops,
#                           the exact role model of audit-roles.sql
#
# Why separate ROLES and not only separate databases: roles are cluster-wide.
# If staging reused calltype_prod / calltype_audit_app, a staging secret
# (held by a Free-tier App Service with weaker guarantees) would open the
# production databases. With own roles, staging credentials reach staging
# databases only — the isolation is by role, which is the documented beta
# risk in gap-ops.md §8.
#
# Why generated from audit-roles.sql instead of a copy: that file is the one
# source of truth for the audit role model (the integration tests apply it
# verbatim). A copy would drift the first time a table gets a new UPDATE
# grant. The rename below only touches role and database identifiers.
#
# Run as the postgres superuser ON the database server, then set passwords
# interactively (never in a file or on a command line):
#   sudo -u postgres ./staging-databases.sh
#   sudo -u postgres psql -c '\password calltype_staging'   # same for _app, _ops
# Then run the audit EF migrations for staging as calltype_audit_staging_ops
# (docs/ops/staging.md §3) and run THIS script again, so the per-table grants
# of audit-roles.sql reach the tables the migrations just created.
# Re-running is harmless. Staging databases are NOT in backup.sh's default
# DATABASES — they hold only smoke-test data.
# ---------------------------------------------------------------------------
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PSQL=(psql -X -v ON_ERROR_STOP=1 -q)

"${PSQL[@]}" -d postgres <<'EOF'
SELECT 'CREATE ROLE calltype_staging LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'calltype_staging') \gexec
SELECT 'CREATE DATABASE calltype_staging OWNER calltype_staging'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'calltype_staging') \gexec
SELECT 'CREATE DATABASE calltype_audit_staging'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'calltype_audit_staging') \gexec
-- Nobody but the owner roles may connect (PUBLIC has CONNECT by default).
REVOKE CONNECT ON DATABASE calltype_staging FROM PUBLIC;
REVOKE CONNECT ON DATABASE calltype_audit_staging FROM PUBLIC;
EOF

# audit-roles.sql with staging identifiers. Order matters: the longer names
# first, then the database name (whole-word, so calltype_audit_staging_app is
# not renamed twice).
roles_sql="$(mktemp)"; trap 'rm -f "$roles_sql"' EXIT
sed -e 's/\bcalltype_audit_app\b/calltype_audit_staging_app/g' \
    -e 's/\bcalltype_audit_ops\b/calltype_audit_staging_ops/g' \
    -e 's/\bDATABASE calltype_audit\b/DATABASE calltype_audit_staging/g' \
    "$here/audit-roles.sql" > "$roles_sql"
# Guard: no production identifier may survive the rename.
if grep -Eq '\bcalltype_audit_(app|ops)\b|DATABASE calltype_audit\b' "$roles_sql"; then
  echo "refusing: audit-roles.sql contains an identifier the rename did not cover" >&2; exit 2
fi
"${PSQL[@]}" -d calltype_audit_staging -f "$roles_sql"

# audit-roles.sql creates its LOGIN roles with placeholder passwords. On a
# shared server a known placeholder is an open door: lock the staging roles
# until the operator sets real passwords with \password.
"${PSQL[@]}" -d postgres <<'EOF'
ALTER ROLE calltype_audit_staging_app PASSWORD NULL;
ALTER ROLE calltype_audit_staging_ops PASSWORD NULL;
EOF

"${PSQL[@]}" -At -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE '%staging' ORDER BY 1"
echo "OK — now set passwords: \\password calltype_staging / calltype_audit_staging_app / calltype_audit_staging_ops"
