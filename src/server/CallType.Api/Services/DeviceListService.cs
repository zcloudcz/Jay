using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

/// <summary>
/// Routing lookups over device lists. "Identity" = primary device ID; a
/// device that is in no list is its own identity.
/// </summary>
public class DeviceListService(AppDbContext db)
{
    public async Task<Guid> PrimaryOfAsync(Guid deviceId, CancellationToken ct) =>
        await db.DeviceListMembers.Where(m => m.DeviceId == deviceId)
            .Select(m => (Guid?)m.PrimaryDeviceId).FirstOrDefaultAsync(ct) ?? deviceId;

    /// <summary>
    /// Every device of the given identities: the primaries themselves plus
    /// their companions. A companion that deleted itself is already gone here
    /// (FK cascade), which is what lets a sender drop it without a new list.
    /// </summary>
    public async Task<HashSet<Guid>> DevicesOfAsync(IReadOnlyCollection<Guid> primaryIds, CancellationToken ct)
    {
        var devices = primaryIds.ToHashSet();
        devices.UnionWith(await db.DeviceListMembers
            .Where(m => primaryIds.Contains(m.PrimaryDeviceId))
            .Select(m => m.DeviceId).ToListAsync(ct));
        return devices;
    }
}
