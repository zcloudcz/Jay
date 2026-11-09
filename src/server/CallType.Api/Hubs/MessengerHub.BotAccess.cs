// ---------------------------------------------------------------------------
// MessengerHub.BotAccess.cs - bot inbound policy on the send paths
// ---------------------------------------------------------------------------
// Spec docs/superpowers/specs/2026-11-09-bot-access.md A2. The send methods
// in MessengerHub.cs call BotBlockedAsync after their own validation and
// leave the returned devices out of the queue. The caller sees the same
// ack as for a delivered message, so the hub never tells a stranger whether
// a handle is a bot or who owns it.
// ---------------------------------------------------------------------------

namespace CallType.Api.Hubs;

public partial class MessengerHub
{
    /// <summary>
    /// Recipient devices of this send that are bots in mode "owners" and
    /// must not get it: a 1:1 sender (<paramref name="groupMembers"/> null)
    /// that is not an owner identity, or a group without an owner member.
    /// </summary>
    private Task<HashSet<Guid>> BotBlockedAsync(Guid senderPrimary, IEnumerable<Guid> recipients,
        IReadOnlyCollection<Guid>? groupMembers) =>
        botPolicy.BlockedAsync(senderPrimary, recipients.ToList(), groupMembers, Context.ConnectionAborted);
}
