// ---------------------------------------------------------------------------
// UserBlockService.cs - who must not receive a send (spec 2026-11-14-go-live)
// ---------------------------------------------------------------------------
// D2: the hub drops a blocked identity's copies to every device of the
// blocker, on every send path, and answers the sender exactly like a
// delivered message (same "no oracle" rule as BotInboundPolicy).
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

public class UserBlockService(AppDbContext db, DeviceListService deviceLists)
{
    /// <summary>
    /// The devices of <paramref name="recipients"/> whose identity blocked
    /// <paramref name="senderPrimary"/>. The first query asks only "who
    /// blocked this sender?" through the BlockedPrimaryId index; for nearly
    /// every send the answer is nobody and nothing else runs.
    /// </summary>
    public async Task<HashSet<Guid>> BlockedRecipientsAsync(Guid senderPrimary, IReadOnlyCollection<Guid> recipients,
        CancellationToken ct)
    {
        if (recipients.Count == 0) return [];
        var blockers = await BlockersOfAsync(senderPrimary, ct);
        if (blockers.Count == 0) return [];
        var blockerDevices = await deviceLists.DevicesOfAsync(blockers, ct);
        return recipients.Where(blockerDevices.Contains).ToHashSet();
    }

    /// <summary>True when the identity of <paramref name="target"/> blocked the identity of <paramref name="sender"/>.</summary>
    public async Task<bool> IsBlockedAsync(Guid sender, Guid target, CancellationToken ct)
    {
        var (senderPrimary, targetPrimary) = await deviceLists.PrimariesOfAsync(sender, target, ct);
        return await db.UserBlocks.AnyAsync(
            b => b.BlockedPrimaryId == senderPrimary && b.BlockerPrimaryId == targetPrimary, ct);
    }

    private Task<List<Guid>> BlockersOfAsync(Guid senderPrimary, CancellationToken ct) =>
        db.UserBlocks.AsNoTracking()
            .Where(b => b.BlockedPrimaryId == senderPrimary)
            .Select(b => b.BlockerPrimaryId)
            .ToListAsync(ct);
}
