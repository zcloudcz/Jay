// ---------------------------------------------------------------------------
// BusinessGroupService.cs — business group creation + revocation fan-out (E02)
// ---------------------------------------------------------------------------
// KB1 says a business group without its organization's auditor member must
// never exist. CreateAsync enforces that by adding the auditor GroupMember in
// the same SaveChangesAsync call as the group and its other members — EF Core
// wraps a single multi-entity SaveChanges in one implicit transaction, so a
// failure partway through leaves nothing behind rather than an auditor-less
// group.
//
// Only registered in DI when BusinessModeOptions.Enabled (see Program.cs) —
// callers must check that flag before resolving this service.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Audit.Application;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Services;

public record BusinessGroupResult(bool Success, Guid GroupId, string? ErrorCode)
{
    public static BusinessGroupResult Ok(Guid groupId) => new(true, groupId, null);
    public static BusinessGroupResult Fail(string errorCode) => new(false, Guid.Empty, errorCode);
}

public class BusinessGroupService(AppDbContext db, AuditDbContext auditDb, AuditorLivenessService auditorLiveness)
    : IEnrollmentRevokedHandler
{
    /// <summary>
    /// Creates a business group (or business 1:1, which is just this with one
    /// other member) with the organization's auditor as a member — KB1. All
    /// invited members (and the creator) must be actively enrolled in the
    /// organization; otherwise a device outside the org could join a business
    /// conversation the auditor never sees content for.
    /// </summary>
    public async Task<BusinessGroupResult> CreateAsync(Guid organizationId, Guid creatorDeviceId,
        Guid[] memberDeviceIds, CancellationToken ct)
    {
        var auditorDeviceId = await auditDb.Organizations.AsNoTracking()
            .Where(o => o.OrganizationId == organizationId)
            .Select(o => o.AuditorDeviceId)
            .SingleOrDefaultAsync(ct);
        if (auditorDeviceId is null)
            return BusinessGroupResult.Fail("auditor_not_configured");

        // W2-F: a business conversation must not be CREATED while the org's
        // auditor is dead (owner decision 2026-09-18). No emergency exception
        // here — the emergency group is created by EmergencyGroupService, not
        // this path.
        if (!await auditorLiveness.IsAliveAsync(organizationId, ct))
            return BusinessGroupResult.Fail("auditor_unavailable");

        var members = memberDeviceIds.Append(creatorDeviceId).Distinct().ToArray();
        // Cap at 99 + auditor = 100, same ceiling as the anonymous endpoint.
        if (members.Length > 99 || members.Contains(Guid.Empty))
            return BusinessGroupResult.Fail("too_many_members");
        if (await db.Devices.CountAsync(d => members.Contains(d.DeviceId), ct) != members.Length)
            return BusinessGroupResult.Fail("device_not_found");

        var enrolledCount = await auditDb.OrgEnrollments.CountAsync(e =>
            e.OrganizationId == organizationId && e.RevokedAt == null && members.Contains(e.DeviceId), ct);
        if (enrolledCount != members.Length)
            return BusinessGroupResult.Fail("not_enrolled");

        var now = DateTimeOffset.UtcNow;
        var group = new Group
        {
            GroupId = Guid.NewGuid(), CreatedBy = creatorDeviceId, CreatedAt = now, OrganizationId = organizationId
        };
        db.Groups.Add(group);
        db.GroupMembers.AddRange(members.Select(device => new GroupMember
        {
            GroupId = group.GroupId, DeviceId = device,
            Role = device == creatorDeviceId ? "admin" : "member", JoinedAt = now
        }));
        db.GroupMembers.Add(new GroupMember
        {
            GroupId = group.GroupId, DeviceId = auditorDeviceId.Value, Role = "auditor", JoinedAt = now
        });
        await db.SaveChangesAsync(ct);
        return BusinessGroupResult.Ok(group.GroupId);
    }

    /// <summary>
    /// Drops a device from every business group of the organization it was
    /// just un-enrolled from, so it stops receiving future fan-out. Existing
    /// queued ciphertext and archived history are left untouched — the same
    /// "removal doesn't delete history" policy as the anonymous group
    /// member-removal endpoint. The auditor membership itself is never
    /// touched here (KB1 immutability) — revoking the auditor's own device
    /// enrollment is out of scope for this hook.
    /// </summary>
    public async Task OnEnrollmentRevokedAsync(Guid organizationId, Guid deviceId, CancellationToken cancellationToken)
    {
        var memberships = await db.GroupMembers
            .Where(m => m.DeviceId == deviceId && m.Role != "auditor" && m.Group.OrganizationId == organizationId)
            .ToListAsync(cancellationToken);
        if (memberships.Count == 0) return;
        db.GroupMembers.RemoveRange(memberships);
        // Bot conversations: a removed member leaves every bot talk allow list.
        await GroupBotTalkPruning.PruneAsync(db, deviceId, memberships.Select(m => m.GroupId).ToList(), cancellationToken);
        await db.SaveChangesAsync(cancellationToken);
    }
}
