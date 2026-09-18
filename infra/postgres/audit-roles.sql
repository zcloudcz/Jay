-- ---------------------------------------------------------------------------
-- audit-roles.sql — production role model for the Audit database (KB3)
-- ---------------------------------------------------------------------------
-- WHY two roles: the audit trail's entire value is that nobody who can log in
-- as the application can rewrite history. If the running API's own role could
-- UPDATE/DELETE, a stolen app credential (or a bug) could tamper with
-- AuditRecord/AdminAuditEvent and no one would know — the hash chain (KB3)
-- only detects tampering if the tamperer genuinely can't reach UPDATE/DELETE.
-- Splitting the roles means an attacker needs the SEPARATE ops credential
-- (never stored in the running app's configuration) to do anything
-- destructive, and retention (KB3: DROP PARTITION) becomes a deliberate,
-- out-of-band, auditable operation instead of something reachable from a
-- request.
--
-- Run this against the production Audit database AFTER migrations have been
-- applied by the ops role (see below). Adjust the schema name if migrations
-- ever target something other than "public".
--
-- This script is also applied, verbatim, by the CallType.Api.Tests
-- integration fixture against a disposable Testcontainers database to prove
-- the app role really can't UPDATE/DELETE an AuditRecord (see
-- BusinessModeIntegrationTests). Local docker-compose dev does NOT run this
-- script — it uses one convenience role that can also run migrations (see
-- infra/postgres/init-audit-db.sh) because local dev has no attacker model.
-- ---------------------------------------------------------------------------

-- Application role: used by the running API. INSERT for writing new audit
-- records/events, SELECT for reads (admin export, audit-access reads). Never
-- UPDATE/DELETE/TRUNCATE — an append-only log that can't be edited is the
-- whole point of KB3.
CREATE ROLE calltype_audit_app LOGIN PASSWORD 'REPLACE_ME';
GRANT CONNECT ON DATABASE calltype_audit TO calltype_audit_app;
GRANT USAGE ON SCHEMA public TO calltype_audit_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO calltype_audit_app;
-- Sequences back the ValueGeneratedOnAdd() identity columns (AuditRecord.Id,
-- AdminAuditEvent.Id, ...) — INSERT needs USAGE to pull the next value.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO calltype_audit_app;
-- No ALTER DEFAULT PRIVILEGES here on purpose: a future migration adding a
-- table must not silently grant the app role write access to it. The ops
-- role re-runs the relevant GRANT lines of this script after each migration.

-- Migration / ops role: owns the schema, runs `dotnet ef database update
-- --context AuditDbContext`, and is the ONLY role allowed to DROP PARTITION
-- for retention (KB3). Never configured into the running API's connection
-- string (ConnectionStrings:Audit uses calltype_audit_app instead).
CREATE ROLE calltype_audit_ops LOGIN PASSWORD 'REPLACE_ME_OPS';
GRANT ALL PRIVILEGES ON DATABASE calltype_audit TO calltype_audit_ops;
ALTER DATABASE calltype_audit OWNER TO calltype_audit_ops;

-- GRANT ... ON ALL TABLES only covers tables that exist right now. Every later
-- EF migration (run as calltype_audit_ops) creates new tables, and without
-- default privileges the app role could not even read them.
ALTER DEFAULT PRIVILEGES FOR ROLE calltype_audit_ops IN SCHEMA public
    GRANT SELECT, INSERT ON TABLES TO calltype_audit_app;
ALTER DEFAULT PRIVILEGES FOR ROLE calltype_audit_ops IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO calltype_audit_app;
-- The migrations history table is bookkeeping for the ops role only.
REVOKE INSERT ON TABLE "__EFMigrationsHistory" FROM calltype_audit_app;

