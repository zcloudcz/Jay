#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# init-audit-db.sh — local-dev Audit database + role (business mode, E00)
# ---------------------------------------------------------------------------
# Runs once, at first container start, via postgres's own
# docker-entrypoint-initdb.d mechanism (docker-compose.yml mounts this file
# into that directory on the `db` service).
#
# Local dev keeps ONE role with ordinary privileges on the audit database —
# it needs to run EF migrations directly (Database:ApplyMigrationsOnStartup),
# which production's restricted app role must never be able to do. See
# infra/postgres/audit-roles.sql for the production role split (app:
# INSERT/SELECT only, ops: owns the schema) and why it matters (KB3).
# ---------------------------------------------------------------------------
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE USER calltype_audit WITH PASSWORD 'calltype_audit_dev_password';
    CREATE DATABASE calltype_audit OWNER calltype_audit;
EOSQL
