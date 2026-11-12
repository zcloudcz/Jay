// ---------------------------------------------------------------------------
// MessengerHub.Silent.cs - reliable sends that never push
// ---------------------------------------------------------------------------
// Spec docs/superpowers/specs/2026-11-11-bot-ack-reactions.md N1. The server
// cannot see what an envelope holds (E2E), so the SENDER says when a message
// is not worth waking a device for: a bot's acknowledgement reaction. A
// silent message is validated, stored and delivered exactly like the plain
// method; only the "New message" push to an offline device is skipped.
//
// WHY separate methods instead of an optional `silent` argument: SignalR
// binds hub arguments by count, so an optional parameter would break every
// old client calling with the old count. A new name keeps the old methods
// byte for byte, and a new client on an old server gets "Failed to invoke"
// (nothing queued) and falls back to the plain method.
// Nothing is stored about the flag: it only decides the push at send time,
// and no other path pushes a queued message later.
// ---------------------------------------------------------------------------

namespace CallType.Api.Hubs;

public partial class MessengerHub
{
    public Task SendReliableMessageSilent(Guid recipientDeviceId, Guid messageId, string encryptedBodyBase64)
        => SendReliableMessageCore(recipientDeviceId, messageId, encryptedBodyBase64, silent: true);

    public Task SendReliableGroupMessageSilent(Guid groupId, Guid messageId,
        Dictionary<Guid, string> encryptedPayloads)
        => SendReliableGroupMessageCore(groupId, messageId, encryptedPayloads, silent: true);

    public Task SendReliableDirectFanoutSilent(Guid recipientPrimaryId, Guid messageId,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
        => SendReliableDirectFanoutCore(recipientPrimaryId, messageId, allRecipients, encryptedPayloads, silent: true);

    public Task SendReliableGroupFanoutSilent(Guid groupId, Guid messageId,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
        => SendReliableGroupFanoutCore(groupId, messageId, allRecipients, encryptedPayloads, silent: true);
}
