using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

/// <summary>
/// Drops a device from the bot talk allow list of the given groups. Shared by
/// every path that removes a membership (RemoveMember, enrollment revocation)
/// so none of them can forget it. Only tracks the changes; the caller saves
/// them together with the membership removal.
/// </summary>
public static class GroupBotTalkPruning
{
    public static async Task PruneAsync(AppDbContext db, Guid deviceId, IReadOnlyCollection<Guid> groupIds,
        CancellationToken ct)
    {
        if (groupIds.Count == 0) return;
        // Filtered in SQL (uuid[] contains): only groups that actually list
        // the device are loaded, normally none.
        var groups = await db.Groups
            .Where(g => groupIds.Contains(g.GroupId) && g.BotTalk.AllowedBotDeviceIds.Contains(deviceId))
            .ToListAsync(ct);
        foreach (var group in groups)
            // A new list instance, not an in-place Remove: EF snapshots
            // primitive collections, but replacing the value keeps the change
            // detection obvious and independent of comparer details.
            group.BotTalk.AllowedBotDeviceIds = group.BotTalk.AllowedBotDeviceIds.Where(id => id != deviceId).ToList();
    }
}
