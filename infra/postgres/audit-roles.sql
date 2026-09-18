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
-- Not every table in this database is append-only, though: Organizations,
-- OrgMembers, OrgInvites, OrgEnrollments, EmergencyKits,
-- EmergencyEnrollmentCodes and EmergencyDrills hold ordinary mutable state
-- that the application UPDATEs in place (organization settings, membership
-- role/removal, invite/code redemption, kit revocation, drill completion —
-- see the per-table comments below for the exact column and code path).
-- AuditRecords/AdminAuditEvents/AuditAccessLogs/DailyRoots/OrgDailyProofs/
-- EmergencyDrillConfirmations stay INSERT-only: KB3's guarantee only holds
-- for those. AuditAccessRequests is designed to be mutable too (Approve/
-- Reject on the domain type, for the not-yet-built four-eyes flow, E04) but
-- no endpoint writes to it yet — no UPDATE grant until E04 ships and needs one.
--
-- Procedure: on a FRESH install, run in this order — (1) create the
-- calltype_audit database, (2) run this script (creates both roles; the
-- per-table GRANTs below only reach tables that exist yet, i.e. none), (3)
-- run EF migrations as calltype_audit_ops, (4) run this script AGAIN so the
-- per-table grants land on the tables migrations just created. On an
-- EXISTING install, re-running this script after a migration is exactly how
-- new mutable tables get their UPDATE grant (see the ALTER DEFAULT
-- PRIVILEGES note below) — the whole script is written to be safely
-- re-runnable any number of times (CREATE ROLE and every GRANT are
-- idempotent-guarded).
--
-- This script is also applied, verbatim (and twice, to prove the rerun is
-- safe), by the CallType.Api.Tests integration fixture against a disposable
-- Testcontainers database to prove the app role really can't UPDATE/DELETE
-- an AuditRecord (see BusinessModeIntegrationTests) and really CAN perform
-- every mutation the application needs (see AuditRoleMutationTests).
--
-- Local docker-compose dev does NOT run this script — it uses one
-- convenience role that can also run migrations (see
-- infra/postgres/init-audit-db.sh) because local dev has no attacker model.
-- ---------------------------------------------------------------------------

-- Application role: used by the running API. INSERT for writing new rows,
-- SELECT for reads, UPDATE only on the specific mutable tables granted below.
-- Never DELETE/TRUNCATE — nothing in this database is ever hard-deleted by
-- the application (removal is always a soft "RevokedAt"/"RemovedAt"/"UsedAt"
-- column, i.e. an UPDATE, never a DELETE).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'calltype_audit_app') THEN
        CREATE ROLE calltype_audit_app LOGIN PASSWORD 'REPLACE_ME';
    END IF;
END $$;
GRANT CONNECT ON DATABASE calltype_audit TO calltype_audit_app;
GRANT USAGE ON SCHEMA public TO calltype_audit_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO calltype_audit_app;
-- Sequences back the ValueGeneratedOnAdd() identity columns (AuditRecord.Id,
-- AdminAuditEvent.Id, ...) — INSERT needs USAGE to pull the next value.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO calltype_audit_app;

-- Per-table UPDATE grants for the tables that hold mutable state (KB3 only
-- protects the append-only ones — see the header). Each grant is guarded
-- with to_regclass so re-running this script before migrations have created
-- the table is a no-op instead of an error (same pattern as the
-- __EFMigrationsHistory guard further down).
DO $$
BEGIN
    -- Organization.Rename/ArchivePublicKey/RetentionDays/ArchiveLevel setters
    -- (PATCH /orgs/{id}) and SetAuditorDeviceAsync (PUT /orgs/{id}/auditor).
    IF to_regclass('public."Organizations"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "Organizations" TO calltype_audit_app;
    END IF;
    -- OrgMember.Remove (DELETE /orgs/{id}/members/{accountId}, soft) and
    -- OrgMember.ChangeRole (PUT /orgs/{id}/members/{accountId}).
    IF to_regclass('public."OrgMembers"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "OrgMembers" TO calltype_audit_app;
    END IF;
    -- OrgInvite.Redeem sets UsedAt (POST /orgs/enroll).
    IF to_regclass('public."OrgInvites"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "OrgInvites" TO calltype_audit_app;
    END IF;
    -- OrgEnrollment.RevokedAt (DELETE /orgs/{id}/enrollments/{deviceId}, soft).
    IF to_regclass('public."OrgEnrollments"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "OrgEnrollments" TO calltype_audit_app;
    END IF;
    -- EmergencyKit.RevokedAt (DELETE /orgs/{id}/emergency/kits/{kitId}, soft).
    IF to_regclass('public."EmergencyKits"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "EmergencyKits" TO calltype_audit_app;
    END IF;
    -- EmergencyEnrollmentCode.UsedAt/UsedByDeviceId (POST /orgs/emergency/enroll).
    IF to_regclass('public."EmergencyEnrollmentCodes"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "EmergencyEnrollmentCodes" TO calltype_audit_app;
    END IF;
    -- EmergencyDrill.CompletedAt/ConfirmedMemberCount/ResponseTime
    -- (.../drills/{drillId}/complete).
    IF to_regclass('public."EmergencyDrills"') IS NOT NULL THEN
        GRANT UPDATE ON TABLE "EmergencyDrills" TO calltype_audit_app;
    END IF;
END $$;
-- No ALTER DEFAULT PRIVILEGES for UPDATE: a future migration adding a table
-- must not silently grant the app role write access to it. A new mutable
-- table needs an explicit GRANT added above (and this script re-run after
-- the migration) — the new AuditRoleMutationTests test fails until someone
-- does, which is the point.

-- Migration / ops role: owns the schema, runs `dotnet ef database update
-- --context AuditDbContext`, and is the ONLY role allowed to DROP PARTITION
-- for retention (KB3). Never configured into the running API's connection
-- string (ConnectionStrings:Audit uses calltype_audit_app instead).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'calltype_audit_ops') THEN
        CREATE ROLE calltype_audit_ops LOGIN PASSWORD 'REPLACE_ME_OPS';
    END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE calltype_audit TO calltype_audit_ops;
ALTER DATABASE calltype_audit OWNER TO calltype_audit_ops;

-- GRANT ... ON ALL TABLES only covers tables that exist right now. Every later
-- EF migration (run as calltype_audit_ops) creates new tables, and without
-- default privileges the app role could not even read them. This default is
-- SELECT/INSERT only — i.e. every new table is append-only by default; a
-- table that needs UPDATE (like the ones above) needs an explicit grant.
ALTER DEFAULT PRIVILEGES FOR ROLE calltype_audit_ops IN SCHEMA public
    GRANT SELECT, INSERT ON TABLES TO calltype_audit_app;
ALTER DEFAULT PRIVILEGES FOR ROLE calltype_audit_ops IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO calltype_audit_app;
-- The migrations history table is bookkeeping for the ops role only.
-- Conditional: the table only exists once EF migrations have run. The test
-- fixture builds the schema with EnsureCreated (no history table), and an
-- unconditional REVOKE would abort the whole script with 42P01.
DO $$
BEGIN
    IF to_regclass('public."__EFMigrationsHistory"') IS NOT NULL THEN
        REVOKE INSERT ON TABLE "__EFMigrationsHistory" FROM calltype_audit_app;
    END IF;
END $$;
