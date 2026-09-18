# Jay Business mode — E00 contracts freeze

Frozen by E00 for E01–E07 to build against. Do not rename anything listed
here without updating this file and telling whoever owns the dependent
package. See `docs/superpowers/plans/2026-09-18-business-mode.md` for the
"why" behind every item — this file is only the "what/exact name".

## Projects & ownership

- `src/server/CallType.Audit/` — new class library (net10.0), referenced by
  `CallType.Api`. Folders: `Domain/` (aggregates, enums, `DomainRuleViolation`),
  `Application/` (`HashChain`, `ITimestampAuthority`, `IArchiveKeyStore`,
  `IImmutableStore`), `Infrastructure/` (`AuditDbContext`,
  `AuditDbContextFactory`, `Migrations/`).
- E01 adds `CallType.Audit/Organization/**` (or reuses `Domain`/endpoints as
  needed) + `Endpoints/OrganizationEndpoints.cs` in `CallType.Api`.
- E02 touches only `Hubs/MessengerHub.cs` (KB2 enforcement) and
  `Endpoints/GroupEndpoints.cs` in `CallType.Api` — Delivery side.
- E03 owns `src/bots/jay_archiver/**`, `CallType.Audit/Archive/**` (new
  subfolder), `tools/audit-verify/`.
- E04 owns `CallType.Audit/Access/**` (new subfolder),
  `Endpoints/AuditAccessEndpoints.cs`.
- E07 owns `CallType.Audit/Emergency/**` (new subfolder),
  `Endpoints/EmergencyEndpoints.cs`. The `EmergencyKit`/`EmergencyDrill`
  tables already exist (E00) — E07 does not need its own migration for them.

## Domain entities (`CallType.Audit.Domain`)

All timestamps `DateTimeOffset`, UTC. All hash columns are exactly 32 bytes
(`HashChain.HashLength`).

| Type | Key | Notes |
| --- | --- | --- |
| `Organization` | `OrganizationId` (Guid) | Aggregate root. `Name`, `CreatedAt`, `ArchivePublicKey` (byte[]?), `RetentionDays` (int), `AuditorDeviceId` (Guid?), `ArchiveLevel` (enum, default `Metadata`). Mutate membership only via `AddMember`/`RemoveMember` — never touch `OrgMember` directly. |
| `OrgMember` | (`OrganizationId`, `AccountId`) | `Role` (enum `OrgRole`, stored as string), `AddedAt`, `RemovedAt?`. Constructor is `internal` — created only by `Organization`. |
| `OrgEnrollment` | (`OrganizationId`, `DeviceId`) | `AccountId`, `EnrolledAt`, `RevokedAt?`. Create only via `OrgEnrollment.Enroll(invite, deviceId, accountId, now)` — this also redeems the invite. |
| `OrgInvite` | `InviteId` (Guid) | `Code` (unique), `IssuedByAccountId`, `IssuedAt`, `ExpiresAt`, `UsedAt?`. |
| `AuditRecord` | `Id` (long, identity) | See KB3 fields below. Unique index on (`OrganizationId`, `Sequence`) and on (`OrganizationId`, `MessageId`) — the latter is what makes archiving idempotent under ACK retry. |
| `AdminAuditEvent` | `Id` (long, identity) | `ActorAccountId`, `EventType` (string), `DetailsJson` (string — never message content), `OccurredAt`, own `Sequence`/`PrevHash`/`Hash` chain, separate from `AuditRecord`'s chain. Unique index on (`OrganizationId`, `Sequence`). |
| `AuditAccessRequest` | `RequestId` (Guid) | `RequesterAccountId`, `Scope`, `Reason`, `RequestedAt`, `ApproverAccountId?`, `ApprovedAt?`, `RejectedAt?`, `WindowExpiresAt?`. Mutate only via `Approve`/`Reject`. |
| `AuditAccessLog` | `Id` (long, identity) | `RequestId`, `OrganizationId`, `AccessorAccountId`, `What` (string), `AccessedAt`. |
| `DailyRoot` | `Day` (DateOnly) | `RootHash`, `TimestampToken?` (byte[]), `TsaName?`, `ExpiresAt?`, `CreatedAt`. |
| `OrgDailyProof` | `Id` (long, identity) | Unique on (`OrganizationId`, `Day`). `ProofPath` (byte[]) — E03 defines the wire format. |
| `EmergencyKit` | `KitId` (Guid) | `RecoveryCodeHash` (string — never the plaintext code), `IssuedAt`, `RevokedAt?`. |
| `EmergencyDrill` | `Id` (long, identity) | `StartedAt`, `CompletedAt?`, `ConfirmedMemberCount`, `ResponseTime?`. |

### Enums (`CallType.Audit.Domain`)

- `ArchiveLevel { Metadata, Full }` — stored as string.
- `OrgRole { Owner, OrgAdmin, AuditorApprover, Member }` — stored as string.

### Domain error codes (`DomainRuleViolation.Code`)

| Code | Thrown by | Meaning |
| --- | --- | --- |
| `multiple_owners` | `Organization.AddMember` | A second active Owner was attempted. |
| `already_member` | `Organization.AddMember` | Account already has an active membership. |
| `last_owner` | `Organization.RemoveMember` | Direct removal of the Owner (no transfer flow exists yet). |
| `last_admin` | `Organization.RemoveMember` | Would remove the last active `OrgAdmin`. |
| `member_not_found` | `Organization.RemoveMember` | No active member with that account id. |
| `invite_invalid` | `OrgInvite.Redeem` (via `OrgEnrollment.Enroll`) | Invite already used or expired. |
| `self_approval` | `AuditAccessRequest.Approve`/`Reject` | Requester == approver. |
| `already_decided` | `AuditAccessRequest.Approve`/`Reject` | Request was already approved/rejected. |

E01/E04 map these to HTTP 409 with the code as the error body's `code` field
(plan §4 already names `last_admin`/`self_approval` as expected 409s).

## `HashChain` API (`CallType.Audit.Application.HashChain`)

```csharp
public static class HashChain
{
    public const int HashLength = 32;
    public static byte[] Genesis { get; } // 32 zero bytes — PrevHash of the first record in any chain.

    public static string Canonicalize(IEnumerable<string?> orderedFieldValues);
    public static byte[] ComputeHash(byte[] prevHash, string canonicalRecord);
}
```

- `Canonicalize` joins values with `` (ASCII Unit Separator); nulls become `""`.
- Callers MUST always serialize a given record type's fields in the same
  fixed order — the order is part of what makes the chain reproducible
  offline (E03's `audit-verify` tool, KB4 acceptance criteria).
- `Hash = ComputeHash(PrevHash, Canonicalize(fields))`. `AuditRecord` and
  `AdminAuditEvent` are separate chains (separate `Sequence` counters) even
  though they share this helper.

## Interfaces (`CallType.Audit.Application`)

- `ITimestampAuthority.StampAsync(byte[] rootHash, CancellationToken)` → `TimestampToken(byte[] Token, string TsaName, DateTimeOffset ExpiresAt)`. E03 provides a deterministic fake for dev/test and an RFC 3161 client for production.
- `IArchiveKeyStore.GetPrivateKeyAsync(Guid organizationId, CancellationToken)` → `byte[]`. Not needed until E03b/E04 (ArchiveLevel.Full); no implementation ships in E00.
- `IImmutableStore.WriteAsync(string path, byte[] content, CancellationToken)`. Optional WORM export adapter for KB4; core must run with none registered.

## Delivery DB (`CallType.Api.Data.AppDbContext`) — additive only

- `Group.OrganizationId` (`Guid?`, indexed). Null = anonymous group (default, unchanged behavior).
- `GroupMember.Role` — allowed values documented in the model comment: `"member"`, `"admin"`, and now `"auditor"` (business mode). E00 only documents the value; E02 owns enforcing "exactly one auditor per business group" and "auditor can't be removed" in the hub/endpoints.
- No FK from Delivery into the Audit database — Delivery only ever stores `OrganizationId` as an opaque Guid.

## DI / configuration (`CallType.Api`)

- `BusinessModeOptions { bool Enabled }` (`CallType.Api.Configuration`) — singleton, `Enabled = !string.IsNullOrEmpty(ConnectionStrings:Audit)`. Inject this and short-circuit with `503 business_mode_disabled` in any E01+/E04/E07 endpoint before touching `AuditDbContext` — it is only registered in DI when `Enabled` is true.
- `AuditDbContext` registered via `AddDbContext<AuditDbContext>` only when `ConnectionStrings:Audit` is set (Npgsql).
- Config key: `ConnectionStrings:Audit` / env `ConnectionStrings__Audit`.
- Config key: `ConnectionStrings:AuditMigrations` / env `ConnectionStrings__AuditMigrations` — schema-owner (ops) role, used ONLY for startup migration of the audit DB when `Database:ApplyMigrationsOnStartup=true`. The app role in `ConnectionStrings:Audit` has INSERT/SELECT only and never runs DDL; without `AuditMigrations` the API logs a warning and leaves the audit schema to the operator.
- `Database:ApplyMigrationsOnStartup` (existing key) now also runs `AuditDbContext.Database.MigrateAsync()` when business mode is enabled.
- `ProductionConfigurationValidator` rejects (by key name only, per existing convention): the well-known dev Postgres password on `ConnectionStrings:Audit`, and `ConnectionStrings:Audit` using the same database login role (`Username`) as `ConnectionStrings:DefaultConnection`, regardless of formatting. Both are no-ops when `ConnectionStrings:Audit` is absent.

## Migrations — how to run them

Two independent `DbContext`s, two independent migration histories, never mixed:

```bash
# Delivery DB (existing)
dotnet ef database update --project src/server/CallType.Api --context AppDbContext

# Audit DB (new)
dotnet ef database update --project src/server/CallType.Audit --context AuditDbContext
```

Adding a migration follows the same `--context` split, e.g.:

```bash
dotnet ef migrations add MyChange --project src/server/CallType.Audit --context AuditDbContext -o Migrations
```

`CallType.Audit` ships its own `IDesignTimeDbContextFactory<AuditDbContext>`
(`Infrastructure/AuditDbContextFactory.cs`) so this works standalone, without
`--startup-project` — its connection string is design-time only, never used
at runtime.

## Local dev (docker-compose) vs. production DB roles

- `docker-compose.yml` now creates a second Postgres database
  (`calltype_audit`) via `infra/postgres/init-audit-db.sh`, owned by one
  convenience role `calltype_audit` that can also run migrations — local dev
  has no attacker model, so it does NOT replicate the production split.
- `infra/postgres/audit-roles.sql` documents (and is applied by
  `BusinessModeIntegrationTests` against a disposable test database) the
  **production** split: `calltype_audit_app` (LOGIN, `SELECT`+`INSERT` only,
  no `UPDATE`/`DELETE`/`TRUNCATE`) for the running API, and
  `calltype_audit_ops` (owns the schema) for migrations and retention
  (`DROP PARTITION`). Never put the ops role's credentials in the running
  API's configuration.

## Test infrastructure

- `CallType.Api.Tests.TestFixtures.IntegrationTestBase` now also creates a
  second database (`calltype_audit`) on the same Testcontainers Postgres
  instance and exposes it as `protected string AuditConnectionString`. It
  sets `ConnectionStrings:Audit` in the test host's config, so
  `AuditDbContext` is registered by `Program.cs` itself — no `ConfigureServices`
  override needed, unlike `AppDbContext`/`BlobServiceClient`.
- Pure-domain unit tests (no DB) live in `CallType.Api.Tests/Audit/` and
  reference `CallType.Audit` transitively through the existing
  `CallType.Api` project reference: `OrganizationTests`,
  `OrgEnrollmentTests`, `AuditAccessRequestTests`, `HashChainTests`. Run with
  `dotnet test src/server/CallType.Api.Tests --filter "FullyQualifiedName~Audit"`.
- `BusinessModeIntegrationTests` (Docker/Testcontainers required — **not run
  on the E00 dev machine**, treat as unverified until someone runs it with
  Docker available) proves the API starts with both databases and that
  `audit-roles.sql`'s app role can't `UPDATE`/`DELETE` an `AuditRecord`.

## Surprises / things E01+ should know

- `OrgMember`/`OrgEnrollment`/`OrgInvite` constructors are `internal` or
  factory-gated on purpose (`Organization.AddMember`/`RemoveMember`,
  `OrgEnrollment.Enroll`) — go through those, not `new OrgMember(...)`, or
  the invariants in this file stop being guaranteed.
- `Organization` has no `TransferOwnership` — removing an Owner always
  throws `last_owner`. If E01 needs ownership transfer, that's new code, not
  something E00 half-built.
- `AuditRecord`/`AdminAuditEvent` are two independent hash chains, not one —
  don't cross-check their `Sequence` numbers against each other.
- The EF Core Npgsql provider was NOT configured with a snake_case naming
  convention — table/column names are PascalCase, matching the existing
  `AppDbContext` convention (e.g. table `"AuditRecords"`, column `"Kind"`).
  `audit-roles.sql`'s quoted identifiers assume this; keep it that way, or
  update both together.

## HashChain rules added in B00 review

- `Canonicalize` encodes `null` as U+0000 (distinct from `""`) and **throws `ArgumentException`** if a value contains U+001F or U+0000. Validate/sanitize free-text input (organization name, access-request reason) at the API boundary and return 422 rather than letting this surface as 500.
- `infra/postgres/audit-roles.sql` sets `ALTER DEFAULT PRIVILEGES` so tables from later migrations are readable/insertable by the app role; migrations must therefore be run as `calltype_audit_ops`.

## E03-lite — archive write API + archiver provisioning (for E05/E07)

### `POST /orgs/{orgId}/audit/records` (`Endpoints/AuditArchiveEndpoints.cs`)

Caller must be authenticated as the organization's `AuditorDeviceId` (403 otherwise; 404 if the org doesn't exist; 503 `business_mode_disabled` if business mode isn't configured).

Request body:
```json
{
  "groupId": "guid",
  "messageId": "guid",
  "senderDeviceId": "guid",
  "sentAt": "2026-09-18T12:00:00Z",
  "kind": "text|attachment|call",
  "sizeBytes": 42,
  "contentHash": "64 hex chars (SHA-256 of the plaintext)"
}
```
- 422 if `kind` isn't one of the three values, `sizeBytes` is negative, or `contentHash` isn't 64 hex chars.
- **Idempotent on `(organizationId, messageId)`** (`MessageId` is already a globally unique GUID per `SendReliableGroupMessage`) — a repeat returns `200` with the *existing* record and appends nothing. This is what makes ACK-after-write safe to retry.
- Response `200`: `AuditRecordDto { organizationId, groupId, messageId, senderDeviceId, sentAt, archivedAt, kind, sizeBytes, contentHash (hex), sequence, hash (hex) }`.
- Sequencing/hash-chaining is optimistic, not lock-based: the app DB role has only `INSERT`/`SELECT` (KB3), so `SELECT ... FOR UPDATE` isn't available (it needs `UPDATE` privilege in Postgres). The endpoint reads the last row, computes the next `Sequence`/`Hash`, and relies on the unique index on `(OrganizationId, Sequence)` to fail concurrent writers, who then retry (bounded, 5 attempts) against a re-read last row. A single archiver process per organization (this package's design) makes contention a non-issue in practice.

### `GET /orgs/{orgId}/audit/records/count` (admins only)

Requires the caller device to be linked (`AppDbContext.AccountDevices`) to an `Account` with an active `OrgMember` role of `Owner` or `OrgAdmin` in that organization (403 otherwise; 404 if org doesn't exist; 503 if business mode disabled). Response: `AuditRecordCountDto { count, lastSequence, lastHash (hex, null if empty) }` — a cheap "is the archive alive" signal, not a substitute for reading the chain.

### `src/bots/jay_archiver` provisioning flow

```
jay_archiver provision --api <url> --org <orgId> --state <dir> --admin-token <jwt>
```
Registers a fresh bot device (`isBot: true`, via `calltype_bot`'s `CallTypeBot.start`), persists its keys in an `EncryptedFileStore` under `<dir>` (needs `BOT_STORE_KEY` in the environment, same convention as `calltype_bot`), then calls `PUT /orgs/{orgId}/auditor { deviceId }` with the **caller-supplied admin JWT** (never the new device's own token — it has no organization membership yet to authorize with). Prints only the device id to stdout.

```
jay_archiver run --api <url> --org <orgId> --state <dir>
```
Connects as the already-provisioned device, decrypts every incoming **group** message in memory (via `GroupMessageSource` — see `lib/src/group_message_source.dart`), and POSTs one metadata record per message, ACKing only after a `2xx` response (K01 discipline — see plan §KB3). Exits non-zero on a `401`/`403` from the archive API (its own credentials are broken); on network errors or `5xx` it retries with capped exponential backoff and, if it still fails, leaves the message un-acked for the server to redeliver later.

`GroupMessageSource` is the seam for step 2 (MLS, plan §6): `SignalGroupMessageSource` is the only implementation today, built on the existing per-recipient Signal fan-out (`calltype_core`'s `SignalRClient` + `SessionManager`) — an MLS-based implementation can replace it later without changing `Archiver`.
