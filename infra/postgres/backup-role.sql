-- ---------------------------------------------------------------------------
-- backup-role.sql — read-only login for infra/postgres/backup.sh (O3 / N05)
-- ---------------------------------------------------------------------------
-- WHY a separate role: backup.sh must read EVERY table of both databases.
-- - calltype_prod (app role of the main DB) could, but its password is the
--   one the running API holds; a cron job's ~/.pgpass must not be a second
--   copy of a credential that can also write and delete.
-- - calltype_audit_app is INSERT/SELECT on purpose (audit-roles.sql) and
--   calltype_audit_ops can change the audit schema — neither belongs in cron.
-- pg_read_all_data (PostgreSQL 14+) is exactly "SELECT on everything, USAGE
-- on every schema", including tables created by future migrations, so no
-- re-grant is needed after a deploy. It cannot write anything.
--
-- Run ONCE as a superuser (postgres) on the database server:
--   psql -U postgres -v ON_ERROR_STOP=1 -f infra/postgres/backup-role.sql
--   psql -U postgres        then:  \password calltype_backup
--                                   ALTER ROLE calltype_backup LOGIN;
-- (password from the password manager, typed at the prompt — never in this
-- file, never on a command line.)
-- Re-running is harmless.
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP on

DO $$
BEGIN
    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION 'pg_read_all_data needs PostgreSQL 14+; on older servers grant SELECT per schema instead (docs/ops/postgres-restore.md §4)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'calltype_backup') THEN
        -- NOLOGIN until the operator sets a password — a login role with an
        -- unknown/placeholder password is worse than one that cannot log in.
        CREATE ROLE calltype_backup NOLOGIN;
    END IF;
END $$;

GRANT pg_read_all_data TO calltype_backup;

DO $$
DECLARE db text;
BEGIN
    FOREACH db IN ARRAY ARRAY['calltype_prod', 'calltype_audit'] LOOP
        IF EXISTS (SELECT 1 FROM pg_database WHERE datname = db) THEN
            EXECUTE format('GRANT CONNECT ON DATABASE %I TO calltype_backup', db);
        END IF;
    END LOOP;
END $$;

-- Evidence: the role exists, can read everything, and cannot write.
SELECT r.rolname, r.rolcanlogin, r.rolsuper, r.rolcreatedb,
       pg_has_role('calltype_backup', 'pg_read_all_data', 'member')  AS read_all,
       pg_has_role('calltype_backup', 'pg_write_all_data', 'member') AS write_all
  FROM pg_roles r WHERE r.rolname = 'calltype_backup';
