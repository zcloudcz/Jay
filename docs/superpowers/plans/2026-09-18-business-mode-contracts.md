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

## E01 — Organization context API (frozen for E02/E03/E05)

All routes below: `RequireAuthorization`, rate limit `api`, and 503
`{ error, code: "business_mode_disabled" }` when `BusinessModeOptions.Enabled`
is false. Identity comes from the JWT device claim; routes that mutate
governance state additionally require the calling device to be linked to a
registered `Account` (403 `{ code: "account_required" }` otherwise) —
enrollment via invite code does not.

| Route | Body | Success | Notes |
| --- | --- | --- | --- |
| `POST /orgs` | `{ name }` | 201 `{ organizationId, name }` | Caller becomes `Owner`. One owned org per account (409 `org_limit`). |
| `GET /orgs/mine` | — | 200 `[{ organizationId, name, role, archiveLevel, auditorDeviceId }]` | Union of account membership and device enrollment. |
| `GET /orgs/{id}` | — | 200 `{ organizationId, name, createdAt, archiveLevel, auditorDeviceId, members: [{ accountId, role, addedAt }] }` | 404 (not 403) for non-members — existence is not leaked. |
| `PATCH /orgs/{id}` | `{ name?, archiveLevel? }` | 204 | OrgAdmin+. |
| `PUT /orgs/{id}/members/{accountId}` | `{ role }` | 204 | OrgAdmin+. `role: "Owner"` → 409 `owner_transfer_unsupported` (no ownership transfer in E01). Uses the new `Organization.ChangeMemberRole` (see below), not Remove+AddMember. |
| `DELETE /orgs/{id}/members/{accountId}` | — | 204 | OrgAdmin+. 409 `last_owner`/`last_admin`, 404 `member_not_found`. |
| `POST /orgs/{id}/invites` | `{ expiresInHours? }` | 200 `{ code, expiresAt }` | OrgAdmin+. Default lifetime 72h. **`maxUses` is not supported** — `OrgInvite` (frozen E00 domain) is single-use only; `maxUses > 1` → 422 `max_uses_unsupported`. |
| `POST /orgs/enroll` | `{ code }` | 200 `{ organizationId }` | Any authenticated device, account optional. 410 `invite_invalid` if unknown/used/expired. |
| `DELETE /orgs/{id}/enrollments/{deviceId}` | — | 204 | OrgAdmin+. Calls `IEnrollmentRevokedHandler.OnEnrollmentRevokedAsync` after commit — see below. |
| `PUT /orgs/{id}/auditor` | `{ deviceId }` | 204 | OrgAdmin+. 422 `auditor_device_invalid` unless the device exists and `Device.IsBot == true`. |
| `GET /orgs/{id}/admin-audit?from&to&format=json\|csv` | — | 200 (JSON array or `text/csv`) | OrgAdmin+. CSV cells starting with `=+-@` are prefixed with `'` (formula-injection guard). |

Error code → HTTP status mapping (`OrganizationEndpoints.MapViolation`):
`org_not_found`/`member_not_found` → 404, `forbidden` → 403, `invite_invalid`
→ 410, `auditor_device_invalid` → 422, everything else (`org_limit`,
`already_member`, `multiple_owners`, `last_owner`, `last_admin`,
`owner_transfer_unsupported`) → 409.

### `IEnrollmentRevokedHandler` (`CallType.Audit.Application`) — E02 seam

```csharp
public interface IEnrollmentRevokedHandler
{
    Task OnEnrollmentRevokedAsync(Guid organizationId, Guid deviceId, CancellationToken ct);
}
```

E01 registers `NoOpEnrollmentRevokedHandler` as the default (singleton) so
`DELETE /orgs/{id}/enrollments/{deviceId}` works before E02 exists. E02
registers its real implementation (removing the device from the
organization's Delivery groups) in `Program.cs`, overriding the default —
last registration wins with `AddSingleton`.

### `IDeliveryDirectory` (`CallType.Audit.Application`) — E01's Delivery seam

```csharp
public interface IDeliveryDirectory
{
    Task<bool> AccountExistsAsync(Guid accountId, CancellationToken ct);
    Task<bool> DeviceExistsAsync(Guid deviceId, CancellationToken ct);
    Task<bool> IsDeviceLinkedToAccountAsync(Guid deviceId, Guid accountId, CancellationToken ct);
    Task<bool> IsBotDeviceAsync(Guid deviceId, CancellationToken ct);
}
```

Implemented by `CallType.Api.Services.DeliveryDirectory` (over `AppDbContext`)
— the only place `CallType.Audit` code reaches Delivery data, kept behind
this interface so `CallType.Audit` never references `AppDbContext` (KB3).

### Domain additions in E01 (on top of E00's frozen `Organization`/`OrgMember`)

E00's `Organization` had no way to change a member's role or rename the org
without violating the `OrgMember` composite key `(OrganizationId, AccountId)`
— rows are soft-deleted (`RemovedAt`), never actually removed, so
Remove+AddMember for the same account would collide on that key. E01 added:

- `Organization.Rename(string name)` — no invariant beyond what EF's
  `MaxLength(200)` already enforces.
- `Organization.ChangeMemberRole(Guid accountId, OrgRole role, DateTimeOffset now)`
  — same invariants as `RemoveMember` (can't touch the Owner's own role,
  can't grant a second Owner, can't demote the last active `OrgAdmin`), new
  codes `owner_transfer_unsupported` (role == Owner) reused from the E01
  endpoint layer, `last_owner`/`last_admin` reused from `RemoveMember`.
- `OrgMember.ChangeRole(OrgRole role)` (internal) — the actual mutation
  `ChangeMemberRole` delegates to.

### KB6 admin audit — `AdminAuditWriter` (`CallType.Audit.OrgManagement`)

Every mutating call above wraps its domain mutation + `AdminAuditWriter.AppendAsync`
+ `SaveChangesAsync` in one `AuditDbContext` transaction. `AppendAsync` takes
a `FOR UPDATE` lock on the organization's last `AdminAuditEvent` row so two
concurrent writers serialize instead of racing on the unique
`(OrganizationId, Sequence)` index. Event types emitted: `org_created`,
`policy_changed`, `member_added`, `member_role_changed`, `member_removed`,
`invite_created`, `device_enrolled`, `enrollment_revoked`, `auditor_device_set`.
`DetailsJson` is a JSON-serialized anonymous object per event type — never
message content, per KB6.

**Note on namespace:** the application-service folder is
`CallType.Audit/Organization/**` (per the ownership table above), but its
namespace is `CallType.Audit.OrgManagement`, not `CallType.Audit.Organization`
— the latter collides with the `Organization` aggregate type itself
(`CS0118: Organization is a namespace but is used like a type`) once a
sibling namespace shares that name. Folder path and namespace are
intentionally different here.
## E02 additions — business groups in Delivery, KB1/KB2 enforcement

- `IEnrollmentRevokedHandler` (`CallType.Audit.Application`, defined by E02
  since E01 hadn't shipped it yet): `Task OnEnrollmentRevokedAsync(Guid organizationId, Guid deviceId, CancellationToken)`.
  Implemented by `CallType.Api.Services.BusinessGroupService`, registered in DI
  (both as itself and as `IEnrollmentRevokedHandler`) only when
  `BusinessModeOptions.Enabled` — E01 resolves it via `IEnrollmentRevokedHandler`
  when it revokes an `OrgEnrollment`.
- `POST /groups/business` — a **new, separate** endpoint (not a field added to
  the existing `POST /groups`), so the anonymous path is untouched. Body:
  `{ organizationId: Guid, memberDeviceIds: Guid[]? }` (caller device is always
  added, same as `/groups`). A business 1:1 is the same call with one other
  member. Responses: `201` with `{ groupId }` (auditor device added with
  `Role = "auditor"` in the same `SaveChangesAsync` as the group); `503
  { error: "business_mode_disabled" }`; `409 { error: "auditor_not_configured" }`
  when `Organization.AuditorDeviceId` is null; `403` when a member (or the
  caller) is not actively enrolled (`OrgEnrollment.RevokedAt == null`) in that
  organization; `400 { error: "too_many_members" | "device_not_found" }`.
- `PUT /groups/{id}/members` now also enforces enrollment when the target
  group has `OrganizationId != null`: `403` if the device isn't actively
  enrolled in that organization.
- `DELETE /groups/{id}/members/{deviceId}` — new `409 { error: "auditor_immutable" }`
  when `deviceId`'s `GroupMember.Role == "auditor"` (KB1: checked before the
  existing last-admin check).
- Hub `SendReliableGroupMessage`/`SendGroupMessage`: when the target group has
  `OrganizationId != null`, `encryptedPayloads` MUST contain an entry for the
  group's `"auditor"` member, or the call throws
  `HubException("audit_recipient_missing")` before any `QueuedMessage` is
  persisted (KB2). Cost: the existing membership query now also selects
  `Role` and `Group.OrganizationId` — no extra round trip. `TypingIndicator`
  and `CallSignal` carry no per-recipient encrypted payload, so KB2 does not
  apply to them; attachments go through the same `SendReliableGroupMessage`
  path as any other encrypted payload, so they're covered.

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

Requires the caller device to be linked (`AppDbContext.AccountDevices`) to an `Account` with an active `OrgMember` role of `Owner` or `OrgAdmin` in that organization (403 otherwise; 404 if org doesn't exist; 503 if business mode disabled). Response: `AuditRecordCountDto { count, lastSequence, lastHash (hex, null if empty), lastArchivedAt (ISO, null if no records), pendingForAuditor (count of the org's auditor device's undelivered QueuedMessage rows), oldestPendingAt (ISO, null if none) }` — a cheap "is the archive alive" signal, not a substitute for reading the chain. `lastArchivedAt`/`pendingForAuditor`/`oldestPendingAt` were added on top of the original `count`/`lastSequence`/`lastHash` (W2-E) so an admin can tell a dead archiver (`pendingForAuditor` growing, `lastArchivedAt` stale) from a healthy but quiet organization; `pendingForAuditor` is 0 and `oldestPendingAt` is null when the org has no `AuditorDeviceId` set yet.

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

## E07 — Emergency channel (spec 2.3/2.6/2.9, plan §5/§7)

Owned files: `CallType.Audit/Emergency/**` (`EmergencyCodes`, `EmergencyAppService`,
`Dtos`), `CallType.Audit/Domain/EmergencyEnrollmentCode.cs` (adds
`EmergencyEnrollmentCode` + `EmergencyDrillConfirmation`), `Endpoints/EmergencyEndpoints.cs`,
`Services/EmergencyGroupService.cs`. Additive migrations: `EmergencyChannel`
(`AuditDbContext` — `EmergencyKit.Label`, the two new tables) and
`EmergencyGroupFlag` (`AppDbContext` — `Group.IsEmergencyChannel`).

**Design deviation from the package brief, called out explicitly:** the brief
says to create the emergency group via `BusinessGroupService`. That method
requires a non-empty, already-enrolled member list (it's built for "user
clicks new business chat") and cannot create a group with only the auditor
before anyone has enrolled. `EmergencyGroupService.EnsureGroupAsync` creates
the group directly instead (still auditor-in-the-same-`SaveChangesAsync`, so
KB1 holds), tagged `Group.IsEmergencyChannel = true` so it can be found again
without guessing among an org's other business groups.

**Drill delivery mechanism chosen:** a dedicated SignalR hub event
`EmergencyDrill { organizationId, drillId, startedAt }`, pushed via
`IHubContext<MessengerHub>` to whichever emergency-group members are online
(`MessengerHub.TryGetConnectionId`, the same per-device connection map
`CallSignal`/`TypingIndicator` use) — not a system group message. No
server-originated group-message path exists in Delivery (`SendReliableGroupMessage`
requires a caller device and per-recipient encrypted payloads, which the
server cannot produce since it never holds plaintext), so a client-visible
event plus a client-side confirm dialog is the mechanism named as the
fallback in the package brief. Offline members simply miss the prompt; that's
consistent with a drill measuring current reachability.

| Route | Auth | Body | Success | Notes |
| --- | --- | --- | --- | --- |
| `POST /orgs/{id}/emergency/kits` | OrgAdmin+ | `{ label, count }` | 200 `{ kitId, label, issuedAt, recoveryCode, codes: string[], printable }` | `count` 1..50 (422 `invalid_count`). Codes/recovery code returned once, plaintext, never persisted. Lazily creates the org's emergency group (409 `auditor_not_configured` if `PUT /orgs/{id}/auditor` hasn't run yet). |
| `GET /orgs/{id}/emergency/kits` | OrgAdmin+ | — | 200 `[{ kitId, label, issuedAt, revokedAt, codesTotal, codesRemaining }]` | Counts only, never codes. |
| `DELETE /orgs/{id}/emergency/kits/{kitId}` | OrgAdmin+ | — | 204 | Idempotent; 404 `kit_not_found`. |
| `POST /orgs/emergency/enroll` | any authenticated device | `{ code }` | 200 `{ organizationId }` | No account/enrollment prerequisite. Rate limit `auth`. 410 `emergency_code_used` / `kit_revoked` / `emergency_code_invalid`. Joins the org's emergency group as a side effect. |
| `POST /orgs/{id}/emergency/drills` | OrgAdmin+ | — | 200 `{ drillId }` | Pushes the `EmergencyDrill` hub event (see above). |
| `POST /orgs/{id}/emergency/drills/{drillId}/confirm` | any enrolled device | — | 204 | First confirmation per device only; ignored once the drill is completed. |
| `POST /orgs/{id}/emergency/drills/{drillId}/complete` | OrgAdmin+ | — | 204 | Idempotent. Stores `ConfirmedMemberCount` and `ResponseTime` = **max** (not median) confirm latency — see `EmergencyAppService.CompleteDrillAsync`. |
| `GET /orgs/{id}/emergency/drills` | OrgAdmin+ | — | 200 `[{ drillId, startedAt, completedAt, confirmedMemberCount, responseTimeSeconds }]` | |
| `GET /orgs/{id}/emergency/proof?format=json\|txt` | OrgAdmin+ | — | 200 `EmergencyProof` (JSON) or `text/plain` | `SelfHashSha256` = SHA-256 over every field except `GeneratedAt` (fixed-order JSON) — reproducible across exports of the same underlying data (`EmergencyProofTests`). Text format applies the same leading `=+-@` escape as `OrganizationEndpoints.EscapeCsv`. |

Error mapping (`EmergencyEndpoints.MapViolation`): `org_not_found`/`kit_not_found`/`drill_not_found`
→ 404, `forbidden` → 403, `kit_revoked`/`emergency_code_used`/`emergency_code_invalid`
→ 410, `invalid_count`/`invalid_label` → 422, else 409.

Admin-audit event types added: `emergency_kit_issued`, `emergency_kit_revoked`,
`emergency_device_enrolled`, `emergency_drill_started`, `emergency_drill_completed`.

**Known limitation — no cross-database transaction on enroll:**
`EmergencyAppService.EnrollAsync` marks the code `UsedAt` (Audit DB) and
commits *before* `EmergencyEndpoints.Enroll` calls `EmergencyGroupService` to
add the device to the Delivery-DB emergency group. These are two physically
separate databases (KB3) with separate credentials, so there is no
distributed transaction tying them together. If the process crashes or the
Delivery write fails between the two calls, the code is burned (marked used,
so it can never be retried) but the device never joined the group.
**Operator remedy: issue the device a new code** (`POST
.../emergency/kits`) — there is no automatic reconciliation, and none is
planned; the two-database split (an explicit KB3 requirement, so a
compromised Delivery DB can never touch archive data) makes a single atomic
commit structurally impossible here, the same tradeoff `OrgEnrollment.Enroll`
already accepts for the ordinary invite-enroll path. A retry-safe redesign
(e.g. a Delivery-side outbox reconciled against Audit DB state) is future
work if this proves to bite in practice, not attempted in E07.

**Not implemented in the first pass, completed in the second commit (see E07
final report):** client UI (`lib/features/organization/emergency/**`,
`calltype_core/lib/network/emergency_api.dart`), the `EmergencyDrill` hub
handler in `signalr_client.dart`, ARB strings in all 19 locales, and widget
tests. The Testcontainers integration suite (`EmergencyEndpointsTests.cs`)
was added compile-only and is `BLOCKED` — no Docker on this machine, same
status as `BusinessModeIntegrationTests`/`AuditArchiveEndpointsTests`.
