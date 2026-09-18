// ---------------------------------------------------------------------------
// OrganizationAppService.cs — Organization context application service (E01)
// ---------------------------------------------------------------------------
// Thin orchestration layer: loads the Organization aggregate, delegates
// invariant enforcement to it (AddMember/RemoveMember), and writes the
// matching AdminAuditEvent (KB6) in the same transaction. Endpoint-level
// concerns (HTTP status mapping, JWT claim extraction, rate limiting) stay in
// CallType.Api.Endpoints.OrganizationEndpoints — this class only knows
// Guids, roles and DateTimeOffsets.
//
// Error signalling: throws DomainRuleViolation for every failure, including
// ones that aren't aggregate invariants (e.g. "org_not_found", "forbidden",
// "org_limit") — the endpoint layer maps DomainRuleViolation.Code to HTTP
// status uniformly instead of having two different error shapes.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using CallType.Audit.Application;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Audit.OrgManagement;

public class OrganizationAppService(AuditDbContext db, IDeliveryDirectory delivery, IEnrollmentRevokedHandler enrollmentRevoked)
{
    private static readonly TimeSpan DefaultInviteLifetime = TimeSpan.FromHours(72);

    // -----------------------------------------------------------------
    // POST /orgs
    // -----------------------------------------------------------------
    public async Task<Guid> CreateOrganizationAsync(Guid ownerAccountId, string name, DateTimeOffset now, CancellationToken ct)
    {
        // [PŘEDPOKLAD 2, accepted]: one owned org per account. Checked here
        // (application policy), not in the Organization aggregate itself —
        // it spans organizations, which no single aggregate instance can see.
        var alreadyOwnsOne = await db.OrgMembers
            .AnyAsync(m => m.AccountId == ownerAccountId && m.Role == OrgRole.Owner && m.RemovedAt == null, ct);
        if (alreadyOwnsOne)
            throw new DomainRuleViolation("org_limit", "Account already owns an organization.");

        var organizationId = Guid.NewGuid();
        var org = Domain.Organization.Create(organizationId, name, ownerAccountId, now);
        db.Organizations.Add(org);

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, ownerAccountId, "org_created",
            new { name }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return organizationId;
    }

    // -----------------------------------------------------------------
    // GET /orgs/mine
    // -----------------------------------------------------------------
    public async Task<List<OrganizationSummary>> GetMyOrganizationsAsync(Guid? accountId, Guid deviceId, CancellationToken ct)
    {
        var result = new List<OrganizationSummary>();
        var membershipOrgIds = new List<Guid>();

        if (accountId is not null)
        {
            var byMembership = await db.Organizations
                .Where(o => o.Members.Any(m => m.AccountId == accountId && m.RemovedAt == null))
                .Select(o => new
                {
                    o.OrganizationId,
                    o.Name,
                    o.ArchiveLevel,
                    o.AuditorDeviceId,
                    Role = o.Members.First(m => m.AccountId == accountId && m.RemovedAt == null).Role
                })
                .ToListAsync(ct);

            foreach (var m in byMembership)
            {
                membershipOrgIds.Add(m.OrganizationId);
                result.Add(new OrganizationSummary(m.OrganizationId, m.Name, m.Role, m.ArchiveLevel, m.AuditorDeviceId));
            }
        }

        var enrolledOrgIds = await db.OrgEnrollments
            .Where(e => e.DeviceId == deviceId && e.RevokedAt == null)
            .Select(e => e.OrganizationId)
            .ToListAsync(ct);
        enrolledOrgIds.RemoveAll(membershipOrgIds.Contains);

        if (enrolledOrgIds.Count > 0)
        {
            var byEnrollment = await db.Organizations
                .Where(o => enrolledOrgIds.Contains(o.OrganizationId))
                .Select(o => new OrganizationSummary(o.OrganizationId, o.Name, OrgRole.Member, o.ArchiveLevel, o.AuditorDeviceId))
                .ToListAsync(ct);
            result.AddRange(byEnrollment);
        }

        return result;
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}
    // -----------------------------------------------------------------
    public async Task<OrganizationDetails> GetOrganizationAsync(Guid organizationId, Guid? accountId, Guid deviceId, CancellationToken ct)
    {
        var org = await LoadOrgAsync(organizationId, ct);
        if (!await IsMemberOrEnrolledAsync(org, accountId, deviceId, ct))
            // 404, not 403 — do not leak whether the org exists to non-members.
            throw new DomainRuleViolation("org_not_found", "Organization not found.");

        return ToDetails(org);
    }

    // -----------------------------------------------------------------
    // PATCH /orgs/{id}
    // -----------------------------------------------------------------
    public async Task UpdateOrganizationAsync(Guid organizationId, Guid actorAccountId, string? name,
        ArchiveLevel? archiveLevel, DateTimeOffset now, CancellationToken ct)
    {
        var org = await LoadOrgForAdminAsync(organizationId, actorAccountId, ct);

        var changes = new Dictionary<string, object?>();
        if (name is not null && name != org.Name)
        {
            changes["name"] = new { from = org.Name, to = name };
            org.Rename(name);
        }
        if (archiveLevel is not null && archiveLevel != org.ArchiveLevel)
        {
            changes["archiveLevel"] = new { from = org.ArchiveLevel.ToString(), to = archiveLevel.ToString() };
            org.ArchiveLevel = archiveLevel.Value;
        }
        if (changes.Count == 0) return;

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "policy_changed", changes, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------
    // PUT /orgs/{id}/members/{accountId}
    // -----------------------------------------------------------------
    public async Task SetMemberRoleAsync(Guid organizationId, Guid actorAccountId, Guid targetAccountId,
        OrgRole role, DateTimeOffset now, CancellationToken ct)
    {
        if (role == OrgRole.Owner)
            throw new DomainRuleViolation("owner_transfer_unsupported", "Ownership transfer is not supported yet.");

        var org = await LoadOrgForAdminAsync(organizationId, actorAccountId, ct);
        var existing = org.Members.FirstOrDefault(m => m.AccountId == targetAccountId && m.RemovedAt is null);

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        if (existing is null)
        {
            org.AddMember(targetAccountId, role, now);
            await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "member_added",
                new { targetAccountId, role = role.ToString() }, now, ct);
        }
        else
        {
            var previousRole = existing.Role;
            org.ChangeMemberRole(targetAccountId, role, now);
            await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "member_role_changed",
                new { targetAccountId, from = previousRole.ToString(), to = role.ToString() }, now, ct);
        }
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------
    // DELETE /orgs/{id}/members/{accountId}
    // -----------------------------------------------------------------
    public async Task RemoveMemberAsync(Guid organizationId, Guid actorAccountId, Guid targetAccountId, DateTimeOffset now, CancellationToken ct)
    {
        var org = await LoadOrgForAdminAsync(organizationId, actorAccountId, ct);

        org.RemoveMember(targetAccountId, now); // throws last_owner / last_admin / member_not_found

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "member_removed",
            new { targetAccountId }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/invites
    // -----------------------------------------------------------------
    public async Task<InviteDto> CreateInviteAsync(Guid organizationId, Guid actorAccountId, int? expiresInHours, DateTimeOffset now, CancellationToken ct)
    {
        await LoadOrgForAdminAsync(organizationId, actorAccountId, ct);

        var lifetime = expiresInHours is > 0 ? TimeSpan.FromHours(expiresInHours.Value) : DefaultInviteLifetime;
        var expiresAt = now + lifetime;
        var code = GenerateInviteCode();

        var invite = new OrgInvite(Guid.NewGuid(), organizationId, code, actorAccountId, now, expiresAt);
        db.OrgInvites.Add(invite);

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "invite_created",
            new { expiresAt }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return new InviteDto(code, expiresAt);
    }

    // -----------------------------------------------------------------
    // POST /orgs/enroll
    // -----------------------------------------------------------------
    public async Task<Guid> EnrollAsync(string code, Guid deviceId, Guid? accountId, DateTimeOffset now, CancellationToken ct)
    {
        var invite = await db.OrgInvites.SingleOrDefaultAsync(i => i.Code == code, ct);
        if (invite is null)
            throw new DomainRuleViolation("invite_invalid", "Invite code not found.");

        // OrgEnrollment.Enroll redeems the invite as part of construction —
        // an enrollment can never exist without a validly consumed invite.
        var enrollment = OrgEnrollment.Enroll(invite, deviceId, accountId ?? Guid.Empty, now);
        db.OrgEnrollments.Add(enrollment);

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        // The actor is the enrolling device's account when known, otherwise
        // the invite issuer — an anonymous device has no account to log as actor.
        await AdminAuditWriter.AppendAsync(db, invite.OrganizationId, accountId ?? invite.IssuedByAccountId,
            "device_enrolled", new { deviceId }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return invite.OrganizationId;
    }

    // -----------------------------------------------------------------
    // DELETE /orgs/{id}/enrollments/{deviceId}
    // -----------------------------------------------------------------
    public async Task RevokeEnrollmentAsync(Guid organizationId, Guid actorAccountId, Guid deviceId, DateTimeOffset now, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        var enrollment = await db.OrgEnrollments
            .SingleOrDefaultAsync(e => e.OrganizationId == organizationId && e.DeviceId == deviceId && e.RevokedAt == null, ct);
        if (enrollment is null)
            throw new DomainRuleViolation("member_not_found", "No active enrollment for that device.");

        enrollment.RevokedAt = now;

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "enrollment_revoked",
            new { deviceId }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        // E02 removes the device from the organization's Delivery groups.
        // A no-op handler runs until E02 registers the real one.
        await enrollmentRevoked.OnEnrollmentRevokedAsync(organizationId, deviceId, ct);
    }

    // -----------------------------------------------------------------
    // PUT /orgs/{id}/auditor
    // -----------------------------------------------------------------
    public async Task SetAuditorDeviceAsync(Guid organizationId, Guid actorAccountId, Guid deviceId, DateTimeOffset now, CancellationToken ct)
    {
        var org = await LoadOrgForAdminAsync(organizationId, actorAccountId, ct);

        if (!await delivery.DeviceExistsAsync(deviceId, ct) || !await delivery.IsBotDeviceAsync(deviceId, ct))
            throw new DomainRuleViolation("auditor_device_invalid", "Auditor device must exist and be registered as a bot device.");

        var previous = org.AuditorDeviceId;
        org.AuditorDeviceId = deviceId;

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "auditor_device_set",
            new { from = previous, to = deviceId }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/admin-audit
    // -----------------------------------------------------------------
    public async Task<List<AdminAuditEventDto>> GetAdminAuditAsync(Guid organizationId, Guid actorAccountId,
        DateTimeOffset? from, DateTimeOffset? to, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        var query = db.AdminAuditEvents.AsNoTracking().Where(e => e.OrganizationId == organizationId);
        if (from is not null) query = query.Where(e => e.OccurredAt >= from);
        if (to is not null) query = query.Where(e => e.OccurredAt <= to);

        return await query.OrderBy(e => e.Sequence)
            .Select(e => new AdminAuditEventDto(e.Sequence, e.ActorAccountId, e.EventType, e.DetailsJson, e.OccurredAt))
            .ToListAsync(ct);
    }

    // -----------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------

    private async Task<Domain.Organization> LoadOrgAsync(Guid organizationId, CancellationToken ct)
    {
        var org = await db.Organizations
            .Include(o => o.Members)
            .SingleOrDefaultAsync(o => o.OrganizationId == organizationId, ct);
        if (org is null)
            throw new DomainRuleViolation("org_not_found", "Organization not found.");
        return org;
    }

    /// <summary>Loads the org and asserts the caller is OrgAdmin or Owner — the "OrgAdmin+" bar most mutating endpoints use.</summary>
    private async Task<Domain.Organization> LoadOrgForAdminAsync(Guid organizationId, Guid actorAccountId, CancellationToken ct)
    {
        var org = await LoadOrgAsync(organizationId, ct);
        AssertAdmin(org, actorAccountId);
        return org;
    }

    private async Task RequireAdminAsync(Guid organizationId, Guid actorAccountId, CancellationToken ct)
    {
        var org = await LoadOrgAsync(organizationId, ct);
        AssertAdmin(org, actorAccountId);
    }

    private static void AssertAdmin(Domain.Organization org, Guid actorAccountId)
    {
        var role = org.Members.FirstOrDefault(m => m.AccountId == actorAccountId && m.RemovedAt is null)?.Role;
        if (role is not (OrgRole.Owner or OrgRole.OrgAdmin))
            throw new DomainRuleViolation("forbidden", "Caller is not an org-admin of this organization.");
    }

    private async Task<bool> IsMemberOrEnrolledAsync(Domain.Organization org, Guid? accountId, Guid deviceId, CancellationToken ct)
    {
        if (accountId is not null && org.Members.Any(m => m.AccountId == accountId && m.RemovedAt is null))
            return true;
        return await db.OrgEnrollments.AnyAsync(
            e => e.OrganizationId == org.OrganizationId && e.DeviceId == deviceId && e.RevokedAt == null, ct);
    }

    private static OrganizationDetails ToDetails(Domain.Organization org) => new(
        org.OrganizationId, org.Name, org.CreatedAt, org.ArchiveLevel, org.AuditorDeviceId,
        org.Members.Where(m => m.RemovedAt is null)
            .Select(m => new OrgMemberDto(m.AccountId, m.Role, m.AddedAt))
            .ToList());

    /// <summary>16 random bytes, base32url-ish via base64url — short enough to type, unguessable enough for a single-use invite.</summary>
    private static string GenerateInviteCode() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(16))
            .Replace('+', '-').Replace('/', '_').TrimEnd('=');
}
