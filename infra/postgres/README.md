# PostgreSQL (external server) — I02

CallType's PostgreSQL runs outside Azure on the existing server at `187.127.83.154:5544`
(database + dedicated user `calltype_prod`, per `docs/azure-beta-plan.md`). This directory holds
non-secret configuration examples only; the full runbook (certificates, backup, restore, account
separation) is in `docs/ops/postgres-restore.md`.

## Files

- `pg_hba.conf.example` — `hostssl`-only access rules scoped to the app DB/user/sources. Copy,
  fill in the real IPs/CIDRs from `docs/ops/beta-inventory.md`, and apply on the server; never
  commit the filled-in version if it contains real source IPs the team wants private (IPs here are
  not secrets per se, but keep the actual file server-side, matching this repo's rule of no
  operational server changes from this package).

## What this package did NOT do

No SSH/administrative connection to the external server, no `pg_dump` of production, no
certificate issuance, no `pg_hba.conf` deployment. Those require DB admin access and a service
window that this package does not have — see `docs/ops/evidence/I02.md` for exact blockers.
