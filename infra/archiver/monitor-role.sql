-- ---------------------------------------------------------------------------
-- monitor-role.sql — read-only login for infra/archiver/check-backlog.sh (O4)
-- ---------------------------------------------------------------------------
-- WHY column-level grants and not calltype_backup (pg_read_all_data): the
-- backlog check runs every few minutes and may send its result to a chat
-- webhook. It needs four columns of one table in each database — not account
-- e-mails, push tokens or message blobs. A leaked monitor password then
-- reveals "how many messages wait for which auditor device", nothing else.
--
-- Run as the postgres superuser on the database server, AFTER both schemas
-- exist (the grants name concrete columns):
--   psql -U postgres -v ON_ERROR_STOP=1 -f infra/archiver/monitor-role.sql
--   psql -U postgres     then:  \password calltype_monitor
--                               ALTER ROLE calltype_monitor LOGIN;
-- Re-running is harmless. pg_hba.conf: loopback only
--   hostssl calltype_prod,calltype_audit calltype_monitor 127.0.0.1/32 scram-sha-256
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP on

\connect postgres
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'calltype_monitor') THEN
        -- NOLOGIN until the operator sets a real password (see header).
        CREATE ROLE calltype_monitor NOLOGIN;
    END IF;
END $$;
GRANT CONNECT ON DATABASE calltype_prod TO calltype_monitor;
GRANT CONNECT ON DATABASE calltype_audit TO calltype_monitor;

-- The auditor's queue: exactly the columns AuditorLivenessService reads.
\connect calltype_prod
GRANT USAGE ON SCHEMA public TO calltype_monitor;
GRANT SELECT ("RecipientId", "GroupId", "AcknowledgedAt", "CreatedAt")
   ON TABLE "QueuedMessages" TO calltype_monitor;

-- Which device is which organization's auditor.
\connect calltype_audit
GRANT USAGE ON SCHEMA public TO calltype_monitor;
GRANT SELECT ("OrganizationId", "AuditorDeviceId")
   ON TABLE "Organizations" TO calltype_monitor;
