using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

/// <summary>
/// Server side of a bot's inbound policy (spec 2026-11-09-bot-access A2):
/// which recipient devices of a send must NOT get their copy because they
/// are bots in mode "owners" and the sender (1:1) or the group (group send)
/// does not qualify.
///
/// WHY the caller silently skips those copies instead of failing the send:
/// an error would tell any stranger whether a handle is a bot, and whose
/// (bot-access A2: "no oracle"). The sender gets the same ack as a success.
/// </summary>
public class BotInboundPolicy(AppDbContext db)
{
    public const string ModeOpen = "open";
    public const string ModeOwners = "owners";

    /// <summary>Most owners one policy may name (A1).</summary>
    public const int MaxOwners = 10;

    /// <summary>
    /// The devices of <paramref name="recipients"/> that must not receive
    /// this send. <paramref name="groupMembers"/> are the group's member
    /// identities for a group send, null for a 1:1 send.
    /// ONE query over the recipients, and only bots in mode "owners" come
    /// back, so a send without such a bot costs one cheap primary-key lookup.
    /// </summary>
    public async Task<HashSet<Guid>> BlockedAsync(Guid senderPrimary, IReadOnlyCollection<Guid> recipients,
        IReadOnlyCollection<Guid>? groupMembers, CancellationToken ct)
    {
        if (recipients.Count == 0) return [];
        var bots = await db.Devices.AsNoTracking()
            .Where(d => recipients.Contains(d.DeviceId) && d.IsBot && d.BotInboundMode == ModeOwners)
            .Select(d => new { d.DeviceId, d.BotInboundOwnerIds })
            .ToListAsync(ct);
        var blocked = new HashSet<Guid>();
        foreach (var bot in bots)
        {
            var owners = bot.BotInboundOwnerIds ?? [];
            // The bot itself (its own copies) and its owners always pass.
            var allowed = senderPrimary == bot.DeviceId || (groupMembers is null
                ? owners.Contains(senderPrimary)
                // Group rule: membership at send time, so removing the last
                // owner from a group cuts the bot off from it at once.
                : owners.Any(o => groupMembers.Contains(o)));
            if (!allowed) blocked.Add(bot.DeviceId);
        }
        return blocked;
    }
}
