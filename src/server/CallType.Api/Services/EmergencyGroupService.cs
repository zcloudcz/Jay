// ---------------------------------------------------------------------------
// EmergencyGroupService.cs — the Delivery-side half of E07 (KB1)
// ---------------------------------------------------------------------------
// CallType.Audit's EmergencyAppService never touches AppDbContext (KB3), so
// everything that needs the organization's emergency GROUP — as opposed to
// its kits/codes/drills, which live in the Audit DB — is here instead.
//
// Deliberately NOT built on BusinessGroupService.CreateAsync: that method
// requires a non-empty, already-enrolled member list (it's designed for a
// human clicking "new business chat"), but the emergency group must exist
// with only the auditor as soon as the first kit is issued — before anyone
// has enrolled. So this service creates/loads the group directly, still
// honoring KB1 (auditor added in the same SaveChangesAsync as the group).
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Services;

public class EmergencyGroupService(AppDbContext db)
{
    /// <summary>Creates the organization's emergency group if it doesn't exist yet. Returns its id.</summary>
    public async Task<Guid> EnsureGroupAsync(Guid organizationId, Guid auditorDeviceId, CancellationToken ct)
    {
        var existing = await db.Groups.AsNoTracking()
            .Where(g => g.OrganizationId == organizationId && g.IsEmergencyChannel)
            .Select(g => g.GroupId)
            .SingleOrDefaultAsync(ct);
        if (existing != Guid.Empty) return existing;

        var now = DateTimeOffset.UtcNow;
        var group = new Group
        {
            GroupId = Guid.NewGuid(), CreatedBy = auditorDeviceId, CreatedAt = now,
            OrganizationId = organizationId, IsEmergencyChannel = true
        };
        db.Groups.Add(group);
        db.GroupMembers.Add(new GroupMember { GroupId = group.GroupId, DeviceId = auditorDeviceId, Role = "auditor", JoinedAt = now });

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            // Lost a race with a concurrent kit issue creating the same group —
            // fall back to whatever the winner created.
            db.Entry(group).State = EntityState.Detached;
            existing = await db.Groups.AsNoTracking()
                .Where(g => g.OrganizationId == organizationId && g.IsEmergencyChannel)
                .Select(g => g.GroupId).SingleAsync(ct);
            return existing;
        }
        return group.GroupId;
    }

    /// <summary>Adds an enrolled device to the organization's emergency group (idempotent).</summary>
    public async Task AddMemberAsync(Guid groupId, Guid deviceId, CancellationToken ct)
    {
        var already = await db.GroupMembers.AnyAsync(m => m.GroupId == groupId && m.DeviceId == deviceId, ct);
        if (already) return;
        db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = deviceId, Role = "member", JoinedAt = DateTimeOffset.UtcNow });
        await db.SaveChangesAsync(ct);
    }

    /// <summary>Device ids of every current member of the org's emergency group (for drill fan-out).</summary>
    public async Task<List<Guid>> GetMemberDeviceIdsAsync(Guid organizationId, CancellationToken ct)
    {
        return await db.GroupMembers
            .Where(m => m.Group.OrganizationId == organizationId && m.Group.IsEmergencyChannel)
            .Select(m => m.DeviceId)
            .ToListAsync(ct);
    }
}
