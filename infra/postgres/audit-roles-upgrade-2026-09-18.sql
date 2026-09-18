-- ---------------------------------------------------------------------------
-- audit-roles-upgrade-2026-09-18.sql — W2-D: add missing UPDATE grants
-- ---------------------------------------------------------------------------
-- One-time fix for an EXISTING installation (beta) that already applied the
-- old audit-roles.sql, which granted calltype_audit_app only SELECT/INSERT —
-- with no UPDATE anywhere. That is correct for the append-only tables, but
-- several tables hold ordinary mutable state the application UPDATEs
-- (organization settings, membership, invite/code redemption, kit/enrollment
-- revocation, drill completion — see infra/postgres/audit-roles.sql for the
-- full per-table rationale). Until this runs, every one of those write paths
-- fails with PostgreSQL 42501 (insufficient_privilege) -> HTTP 500.
--
-- Run ONCE, as the owner/ops role (calltype_audit_ops), against the
-- production calltype_audit database. Idempotent (GRANT is safe to re-run),
-- but there is no need to run it twice.
-- ---------------------------------------------------------------------------

GRANT UPDATE ON TABLE "Organizations" TO calltype_audit_app;
GRANT UPDATE ON TABLE "OrgMembers" TO calltype_audit_app;
GRANT UPDATE ON TABLE "OrgInvites" TO calltype_audit_app;
GRANT UPDATE ON TABLE "OrgEnrollments" TO calltype_audit_app;
GRANT UPDATE ON TABLE "EmergencyKits" TO calltype_audit_app;
GRANT UPDATE ON TABLE "EmergencyEnrollmentCodes" TO calltype_audit_app;
GRANT UPDATE ON TABLE "EmergencyDrills" TO calltype_audit_app;
