// ---------------------------------------------------------------------------
// ConversationMuteService.cs - Which recipients must not be woken by a push
// ---------------------------------------------------------------------------
// Used by MessengerHub on every send that would push, so it is built to cost
// ONE indexed query per send no matter how many recipients a group message
// has (the per-member query trap on group send). Mutes only suppress the
// push: the message is still queued and delivered on the next connect.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Services;

public class ConversationMuteService(AppDbContext db, TimeProvider clock)
{
    /// <summary>
    /// Returns the subset of <paramref name="recipients"/> that muted this
    /// conversation for this sender. Group message: mutes on
    /// (recipient, groupId). Direct message: mutes on (recipient,
    /// senderPrimary), i.e. the sender's identity, so muting a person also
    /// silences their companions. "bots" mutes apply only when the SENDING
    /// device is a bot (the server knows IsBot, no content needed).
    /// </summary>
    public async Task<HashSet<Guid>> SilencedAsync(IReadOnlyCollection<Guid> recipients,
        Guid sender, Guid senderPrimary, Guid? groupId, CancellationToken ct)
    {
        if (recipients.Count == 0) return [];
        var now = clock.GetUtcNow();
        var mutes = db.ConversationMutes.Where(m => recipients.Contains(m.DeviceId)
            && (m.Until == null || m.Until > now));
        mutes = groupId is { } g
            ? mutes.Where(m => m.GroupId == g)
            : mutes.Where(m => m.PeerPrimaryDeviceId == senderPrimary);
        // The IsBot check is a correlated EXISTS inside the same statement,
        // so "bots" mode costs no second round trip.
        var silenced = await mutes
            .Where(m => m.Mode == ConversationMute.ModeAll
                || (m.Mode == ConversationMute.ModeBots && db.Devices.Any(d => d.DeviceId == sender && d.IsBot)))
            .Select(m => m.DeviceId)
            .ToListAsync(ct);
        return silenced.ToHashSet();
    }

    /// <summary>
    /// Mute of the given conversation as the contract shows it; an expired
    /// mute reads as "off" so clients never have to compare clocks.
    /// </summary>
    public async Task<MuteDto> GetAsync(Guid deviceId, Guid? groupId, Guid? peerPrimary, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var row = await db.ConversationMutes.AsNoTracking()
            .Where(m => m.DeviceId == deviceId && m.GroupId == groupId && m.PeerPrimaryDeviceId == peerPrimary
                && (m.Until == null || m.Until > now))
            .Select(m => new MuteDto(m.Mode, m.Until)).FirstOrDefaultAsync(ct);
        return row ?? new MuteDto(ConversationMute.ModeOff, null);
    }

    /// <summary>
    /// Upsert; "off" deletes the row so the push hot path never scans
    /// rows that silence nothing.
    /// </summary>
    public async Task SetAsync(Guid deviceId, Guid? groupId, Guid? peerPrimary, string mode, DateTimeOffset? until,
        CancellationToken ct, bool retried = false)
    {
        var row = await db.ConversationMutes.SingleOrDefaultAsync(m => m.DeviceId == deviceId
            && m.GroupId == groupId && m.PeerPrimaryDeviceId == peerPrimary, ct);
        if (mode == ConversationMute.ModeOff)
        {
            if (row is not null) db.ConversationMutes.Remove(row);
        }
        else
        {
            if (row is null)
            {
                row = new ConversationMute { DeviceId = deviceId, GroupId = groupId, PeerPrimaryDeviceId = peerPrimary };
                db.ConversationMutes.Add(row);
            }
            row.Mode = mode;
            row.Until = until?.ToUniversalTime();
            row.UpdatedAt = clock.GetUtcNow();
        }
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException) when (!retried && row is not null && db.Entry(row).State == EntityState.Added)
        {
            // Two concurrent first-time PUTs from the same device hit the
            // unique index; the other request already stored a mute, retry
            // once as an update so the last writer wins instead of a 500.
            db.Entry(row).State = EntityState.Detached;
            await SetAsync(deviceId, groupId, peerPrimary, mode, until, ct, retried: true);
        }
    }

    public Task<List<MuteListItemDto>> ListAsync(Guid deviceId, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        // Expired rows are left in place (no cleanup job) but not reported:
        // to the client they are simply "not muted".
        return db.ConversationMutes.AsNoTracking()
            .Where(m => m.DeviceId == deviceId && (m.Until == null || m.Until > now))
            .OrderBy(m => m.Id)
            .Select(m => new MuteListItemDto(m.GroupId, m.PeerPrimaryDeviceId, m.Mode, m.Until))
            .ToListAsync(ct);
    }
}

public record MuteDto(string Mode, DateTimeOffset? Until);
public record MuteListItemDto(Guid? GroupId, Guid? PeerDeviceId, string Mode, DateTimeOffset? Until);
