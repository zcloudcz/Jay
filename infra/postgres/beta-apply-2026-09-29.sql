-- ---------------------------------------------------------------------------
-- beta-apply-2026-09-29.sql — the two pending manual steps on beta, in ONE
-- transaction (docs/superpowers/plans/2026-09-29-gap-ops.md, O1 + O2).
-- ---------------------------------------------------------------------------
-- 1. W2-D role fix: UPDATE grants for the mutable Audit tables
--    (same statements as audit-roles-upgrade-2026-09-18.sql). Without it every
--    organization change on beta fails with 42501 -> HTTP 500.
-- 2. The two Audit-DB migrations deployed code already expects:
--    20260918170446_AuditRecordDetails        (AuditRecords.DetailsJson, H1)
--    20260918190514_OrgRequireBusinessConversations
--                                              (Organizations.RequireBusinessConversations, P1)
--    Without them every archive write and every GET /orgs/* fails on a
--    missing column.
--
-- Why hand-written and not `dotnet ef migrations script --idempotent`: it was
-- prepared in an environment without the .NET SDK. The statements mirror
-- exactly what the two migration classes do (AddColumn text NULL; AddColumn
-- boolean NOT NULL DEFAULT false) in the same guarded form EF's idempotent
-- script uses, so running it next to — or instead of — the generated script
-- is safe: each step checks __EFMigrationsHistory first.
--
-- Run ONCE as calltype_audit_ops against calltype_audit, BEFORE the next
-- deploy of the API:
--   psql "host=187.127.83.154 port=5544 dbname=calltype_audit user=calltype_audit_ops sslmode=require" \
--        -v ON_ERROR_STOP=1 -f infra/postgres/beta-apply-2026-09-29.sql
-- (password via PGPASSWORD / ~/.pgpass, never on the command line)
--
-- Re-running is harmless: GRANTs are idempotent and each migration is
-- skipped when its MigrationId is already recorded.
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on
BEGIN;

-- Precondition: the migration BEFORE these two must already be applied.
-- If beta is further behind than the handoff says, stop instead of
-- applying migrations out of order.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "__EFMigrationsHistory"
                   WHERE "MigrationId" = '20260918065848_EmergencyChannel') THEN
        RAISE EXCEPTION 'calltype_audit is missing 20260918065848_EmergencyChannel — run the full idempotent EF script instead of this file';
    END IF;
END $$;

-- 1. W2-D grants ------------------------------------------------------------
GRANT UPDATE ON TABLE "Organizations" TO calltype_audit_app;
GRANT UPDATE ON TABLE "OrgMembers" TO calltype_audit_app;
GRANT UPDATE ON TABLE "OrgInvites" TO calltype_audit_app;
GRANT UPDATE ON TABLE "OrgEnrollments" TO calltype_audit_app;
GRANT UPDATE ON TABLE "EmergencyKits" TO calltype_audit_app;
GRANT UPDATE ON TABLE "EmergencyEnrollmentCodes" TO calltype_audit_app;
GRANT UPDATE ON TABLE "EmergencyDrills" TO calltype_audit_app;

-- 2a. AuditRecordDetails ----------------------------------------------------
DO $EF$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "__EFMigrationsHistory"
                   WHERE "MigrationId" = '20260918170446_AuditRecordDetails') THEN
        ALTER TABLE "AuditRecords" ADD "DetailsJson" text;
    END IF;
END $EF$;

DO $EF$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "__EFMigrationsHistory"
                   WHERE "MigrationId" = '20260918170446_AuditRecordDetails') THEN
        INSERT INTO "__EFMigrationsHistory" ("MigrationId", "ProductVersion")
        VALUES ('20260918170446_AuditRecordDetails', '10.0.4');
    END IF;
END $EF$;

-- 2b. OrgRequireBusinessConversations --------------------------------------
DO $EF$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "__EFMigrationsHistory"
                   WHERE "MigrationId" = '20260918190514_OrgRequireBusinessConversations') THEN
        ALTER TABLE "Organizations" ADD "RequireBusinessConversations" boolean NOT NULL DEFAULT FALSE;
    END IF;
END $EF$;

DO $EF$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "__EFMigrationsHistory"
                   WHERE "MigrationId" = '20260918190514_OrgRequireBusinessConversations') THEN
        INSERT INTO "__EFMigrationsHistory" ("MigrationId", "ProductVersion")
        VALUES ('20260918190514_OrgRequireBusinessConversations', '10.0.4');
    END IF;
END $EF$;

-- The history table is bookkeeping for the ops role only (audit-roles.sql).
REVOKE INSERT ON TABLE "__EFMigrationsHistory" FROM calltype_audit_app;

COMMIT;

-- Evidence for docs/ops/beta-operations.md ----------------------------------
SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY "MigrationId";
SELECT table_name, column_name, data_type, is_nullable
  FROM information_schema.columns
 WHERE (table_name, column_name) IN (('AuditRecords', 'DetailsJson'),
                                     ('Organizations', 'RequireBusinessConversations'));
SELECT table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE grantee = 'calltype_audit_app' AND privilege_type = 'UPDATE'
 ORDER BY table_name;
