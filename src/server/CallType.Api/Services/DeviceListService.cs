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

    /// <summary>Primary of each given device in ONE query; standalone devices map to themselves.</summary>
    public async Task<Dictionary<Guid, Guid>> PrimariesOfManyAsync(IReadOnlyCollection<Guid> deviceIds, CancellationToken ct)
    {
        var rows = await db.DeviceListMembers.Where(m => deviceIds.Contains(m.DeviceId))
            .Select(m => new { m.DeviceId, m.PrimaryDeviceId }).ToListAsync(ct);
        var map = deviceIds.ToDictionary(id => id, id => id);
        foreach (var r in rows) map[r.DeviceId] = r.PrimaryDeviceId;
        return map;
    }

    /// <summary>Both mappings in ONE query (policy hot path).</summary>
    public async Task<(Guid, Guid)> PrimariesOfAsync(Guid a, Guid b, CancellationToken ct)
    {
        var rows = await db.DeviceListMembers.Where(m => m.DeviceId == a || m.DeviceId == b)
            .Select(m => new { m.DeviceId, m.PrimaryDeviceId }).ToListAsync(ct);
        return (rows.FirstOrDefault(r => r.DeviceId == a)?.PrimaryDeviceId ?? a,
                rows.FirstOrDefault(r => r.DeviceId == b)?.PrimaryDeviceId ?? b);
    }

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
