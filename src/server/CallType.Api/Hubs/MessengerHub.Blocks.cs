// ---------------------------------------------------------------------------
// MessengerHub.Blocks.cs - user blocks on the send and call paths
// ---------------------------------------------------------------------------
// Spec docs/superpowers/specs/2026-11-14-go-live.md D2 / S5. The send cores in
// MessengerHub.cs call UserBlockedAsync after their own validation (so a
// dropped copy never hides an error) and leave the returned devices out of
// the queue. The sender sees the same ack as for a delivered message: being
// blocked must not be observable (same "no oracle" rule as the bot policy).
// ---------------------------------------------------------------------------

namespace CallType.Api.Hubs;

public partial class MessengerHub
{
    /// <summary>Recipient devices whose identity blocked <paramref name="senderPrimary"/>.</summary>
    private Task<HashSet<Guid>> UserBlockedAsync(Guid senderPrimary, IEnumerable<Guid> recipients) =>
        userBlocks.BlockedRecipientsAsync(senderPrimary, recipients.ToList(), Context.ConnectionAborted);

    /// <summary>
    /// A call signal from <paramref name="sender"/> to a device whose identity
    /// blocked it is dropped whatever its type: no relay, no pending call, no
    /// ring push. The caller just hears nobody answer.
    /// </summary>
    private Task<bool> CallBlockedAsync(Guid sender, Guid target) =>
        userBlocks.IsBlockedAsync(sender, target, Context.ConnectionAborted);
}
