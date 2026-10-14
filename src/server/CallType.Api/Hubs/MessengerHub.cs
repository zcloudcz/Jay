// ---------------------------------------------------------------------------
// MessengerHub.cs — SignalR hub for real-time message relay
// ---------------------------------------------------------------------------
// The hub is the real-time transport layer. It tracks which devices are
// connected (by mapping DeviceId -> ConnectionId) and routes encrypted
// payloads between them. When a recipient is offline, messages are queued
// via MessageQueueService for later delivery.
//
// The server NEVER decrypts message content — all payloads are opaque
// encrypted blobs passed through as-is. This is a fundamental design
// constraint of an E2E encrypted messenger.
//
// Connection tracking uses ConcurrentDictionary because SignalR may invoke
// OnConnectedAsync/OnDisconnectedAsync from different threads concurrently.
// A plain Dictionary + lock would work but ConcurrentDictionary is simpler
// and has less contention under high connection churn.
//
// Authentication: [Authorize] requires a valid JWT. The deviceId is extracted
// from the "sub" claim — no longer from the spoofable query string. The JWT
// is passed as a query parameter during the WebSocket upgrade because
// WebSocket does not support custom HTTP headers; the JwtBearerEvents in
// Program.cs moves it to the auth context.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Caching.Memory;
using CallType.Api.Endpoints;
using CallType.Api.Services;
using CallType.Api.Data;
using CallType.Api.Models;
using Microsoft.EntityFrameworkCore;

namespace CallType.Api.Hubs;

[Authorize]
public class MessengerHub(MessageQueueService queueService, PushNotificationService pushService, AppDbContext db,
    AuditorLivenessService auditorLiveness, OrgCommunicationPolicy communicationPolicy, IMemoryCache cache,
    DeviceListService deviceLists) : Hub
{
    // Maps DeviceId -> ConnectionId for all currently connected devices.
    // Static because SignalR creates a new Hub instance per invocation,
    // but we need the connection map to survive across all instances.
    private static readonly ConcurrentDictionary<Guid, string> OnlineDevices = new();

    /// <summary>
    /// Lets REST endpoints push an event to a device that is connected right
    /// now (device list changes). Read-only view of the connection map.
    /// </summary>
    internal static bool TryGetConnection(Guid deviceId, out string connectionId) =>
        OnlineDevices.TryGetValue(deviceId, out connectionId!);


    public override async Task OnConnectedAsync()
    {
        await base.OnConnectedAsync();
        var deviceId = GetDeviceId();
        if (deviceId != Guid.Empty)
        {
            OnlineDevices[deviceId] = Context.ConnectionId;
            await SendPendingAsync(deviceId);
        }
    }

    public Task RequestPendingMessages()
        => SendPendingAsync(GetCallerDeviceId() ?? throw new HubException("Invalid device identity"));

    private async Task SendPendingAsync(Guid deviceId)
    {
        var queued = await queueService.DequeueAsync(deviceId, Context.ConnectionAborted);
        foreach (var msg in queued)
            await Clients.Caller.SendAsync("ReceiveMessage", new
            {
                senderId = msg.SenderId,
                encryptedBody = Convert.ToBase64String(msg.EncryptedBody),
                createdAt = msg.CreatedAt,
                messageId = msg.MessageId,
                groupId = msg.GroupId
            }, Context.ConnectionAborted);
    }
    public override Task OnDisconnectedAsync(Exception? exception)
    {
        var deviceId = GetDeviceId();

        if (deviceId != Guid.Empty)
        {
            // Only remove if the stored connection ID matches ours — prevents
            // a stale disconnect from removing a newer reconnection's entry.
            OnlineDevices.TryRemove(new KeyValuePair<Guid, string>(deviceId, Context.ConnectionId));
        }

        return base.OnDisconnectedAsync(exception);
    }

    /// <summary>
    /// Persists encrypted messages before delivery and retains them until acknowledgement.
    /// </summary>
    public Task SendMessage(Guid recipientDeviceId, string encryptedBodyBase64)
        => SendReliableMessage(recipientDeviceId, Guid.NewGuid(), encryptedBodyBase64);

    public async Task SendReliableMessage(Guid recipientDeviceId, Guid messageId, string encryptedBodyBase64)
    {
        var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        // P1: an organization can require that two of its enrolled devices
        // only talk inside a business conversation. Checked before anything
        // is queued, same discipline as KB2's audit_recipient_missing check.
        if (!await communicationPolicy.IsAllowedAsync(sender, recipientDeviceId, Context.ConnectionAborted))
            throw new HubException("business_conversation_required");
        var body = DecodePayload(encryptedBodyBase64);
        var message = await queueService.EnqueueReliableAsync(recipientDeviceId, sender, messageId,
            body, cancellationToken: Context.ConnectionAborted);
        await DeliverAsync(message);
    }

    public Task SendGroupMessage(Guid groupId, Dictionary<Guid, string> encryptedPayloads)
        => SendReliableGroupMessage(groupId, Guid.NewGuid(), encryptedPayloads);

    public async Task SendReliableGroupMessage(Guid groupId, Guid messageId, Dictionary<Guid, string> encryptedPayloads)
    {
        if (encryptedPayloads.Count > 256)
            throw new HubException("Group message exceeds maximum member count");
        var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        // Single query carries both membership and the auditor lookup (KB2) —
        // Group.OrganizationId and Role come along for free on each row, so
        // enforcing KB2 costs no extra round trip over the membership check
        // that already existed here.
        var membership = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Select(m => new { m.DeviceId, m.Role, m.Group.OrganizationId, m.Group.IsEmergencyChannel })
            .ToListAsync(Context.ConnectionAborted);
        var members = membership.Select(m => m.DeviceId).ToList();
        if (!members.Contains(sender) || encryptedPayloads.Keys.Any(id => !members.Contains(id)))
            throw new HubException("Sender and recipients must be group members");
        var isBusinessGroup = membership.Count > 0 && membership[0].OrganizationId is not null;
        // W2-F — owner decision 2026-09-18: business communication is
        // fail-closed on a dead auditor. The emergency group is the one
        // deliberate exception (it exists for the moment infrastructure is
        // failing) — messages there just wait in the auditor's queue.
        if (isBusinessGroup && !membership[0].IsEmergencyChannel
            && !await auditorLiveness.IsAliveAsync(membership[0].OrganizationId!.Value, Context.ConnectionAborted))
            throw new HubException("auditor_unavailable");
        // KB2 — server-side enforcement: a business group's fan-out must
        // always include a payload for the organization's auditor device, or
        // the message would never reach the archive. The auditor row is
        // added atomically with the group (BusinessGroupService), so its
        // absence here means either not a business group (OrganizationId ==
        // null, skip) or a bug/tamper attempt.
        if (isBusinessGroup)
        {
            var auditorDeviceId = membership.SingleOrDefault(m => m.Role == "auditor")?.DeviceId;
            if (auditorDeviceId is null || !encryptedPayloads.ContainsKey(auditorDeviceId.Value))
                throw new HubException("audit_recipient_missing");
        }
        else
        {
            // P1: an anonymous group is one of the paths RequireBusinessConversations
            // covers. Cheap simplification: check sender against each recipient
            // only, not every recipient pair — a pair where NEITHER is the
            // sender is covered when either of THEM sends into this same
            // group, so it's caught, just not on this particular call.
            foreach (var recipient in encryptedPayloads.Keys.Where(id => id != sender))
                if (!await communicationPolicy.IsAllowedAsync(sender, recipient, Context.ConnectionAborted))
                    throw new HubException("business_conversation_required");
        }
        var decoded = encryptedPayloads.Where(p => p.Key != sender)
            .ToDictionary(p => p.Key, p => DecodePayload(p.Value));
        var messages = new List<QueuedMessage>();
        await using (var transaction = await db.Database.BeginTransactionAsync(Context.ConnectionAborted))
        {
            foreach (var (recipient, body) in decoded)
                messages.Add(await queueService.EnqueueReliableAsync(recipient, sender, messageId,
                    body, groupId, Context.ConnectionAborted));
            await transaction.CommitAsync(Context.ConnectionAborted);
        }
        foreach (var message in messages)
            await DeliverAsync(message);
    }

    // -----------------------------------------------------------------------
    // Multi-device fan-out
    // -----------------------------------------------------------------------
    // An identity is a primary device plus the companions in its signed list.
    // The sender encrypts one copy per device; this hub checks that the set
    // of target devices is exactly "every device of the recipient identities
    // and of the sender's own identity". It never looks at the signed list
    // itself: clients verify it. If the hub and a client disagree, the send
    // fails (device_list_stale) and the client re-reads the list. The hub can
    // therefore withhold a device, but it cannot make a client encrypt for
    // one the client did not verify.

    public async Task SendReliableDirectFanout(Guid recipientPrimaryId, Guid messageId,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
    {
        var ct = Context.ConnectionAborted;
        var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        var senderPrimary = await deviceLists.PrimaryOfAsync(sender, ct);
        // Conversations are keyed by identity: addressing a companion would
        // open a second conversation with the same person on the other side.
        if (await deviceLists.PrimaryOfAsync(recipientPrimaryId, ct) != recipientPrimaryId)
            throw new HubException("recipient_is_not_primary");
        // Policy over identities: otherwise an enrolled employee would step
        // around RequireBusinessConversations through a companion device.
        if (!await communicationPolicy.IsAllowedAsync(senderPrimary, recipientPrimaryId, ct))
            throw new HubException("business_conversation_required");
        var required = await deviceLists.DevicesOfAsync([recipientPrimaryId, senderPrimary], ct);
        await FanoutAsync(sender, messageId, null, required, allRecipients, encryptedPayloads);
    }

    public async Task SendReliableGroupFanout(Guid groupId, Guid messageId,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
    {
        var ct = Context.ConnectionAborted;
        var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        var senderPrimary = await deviceLists.PrimaryOfAsync(sender, ct);
        var membership = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Select(m => new { m.DeviceId, m.Group.OrganizationId }).ToListAsync(ct);
        var members = membership.Select(m => m.DeviceId).ToList();
        if (!members.Contains(senderPrimary))
            throw new HubException("Sender and recipients must be group members");
        // Business groups stay on SendReliableGroupMessage (primary devices
        // only): KB2 auditor rules and the archive are defined over members,
        // and companions there need their own analysis.
        if (membership[0].OrganizationId is not null)
            throw new HubException("fanout_unsupported_in_business_group");
        foreach (var member in members.Where(id => id != senderPrimary))
            if (!await communicationPolicy.IsAllowedAsync(senderPrimary, member, ct))
                throw new HubException("business_conversation_required");
        var required = await deviceLists.DevicesOfAsync(members, ct);
        await FanoutAsync(sender, messageId, groupId, required, allRecipients, encryptedPayloads);
    }

    private async Task FanoutAsync(Guid sender, Guid messageId, Guid? groupId, HashSet<Guid> required,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
    {
        required.Remove(sender);
        // Own error text: this cap counts DEVICES (companions included), so the
        // group-message wording "maximum member count" would mislead.
        if (required.Count > 256)
            throw new HubException("fanout_too_many_devices");
        // Completeness is checked on the declared set, not on the payloads of
        // this call: an attachment for several devices does not fit one 1 MiB
        // frame, so a client may split the payloads over several calls.
        if (!required.SetEquals(allRecipients))
            throw new HubException("device_list_stale:" + string.Join(',', required));
        if (encryptedPayloads.Count == 0 || encryptedPayloads.Keys.Any(id => !required.Contains(id)))
            throw new HubException("Fan-out payloads must target declared recipients");
        var decoded = encryptedPayloads.ToDictionary(p => p.Key, p => DecodePayload(p.Value));
        var messages = new List<QueuedMessage>();
        await using (var transaction = await db.Database.BeginTransactionAsync(Context.ConnectionAborted))
        {
            foreach (var (recipient, body) in decoded)
                messages.Add(await queueService.EnqueueReliableAsync(recipient, sender, messageId,
                    body, groupId, Context.ConnectionAborted));
            await transaction.CommitAsync(Context.ConnectionAborted);
        }
        foreach (var message in messages)
            await DeliverAsync(message);
    }

    // -----------------------------------------------------------------------
    // Device linking relay
    // -----------------------------------------------------------------------
    // Two tiny messages between a primary and the device it is about to
    // link. Nothing is stored and nothing here is trusted: the primary got
    // the new device's keys from a QR code, and the consent is a signature
    // the primary verifies. Both sides must be online, linking is interactive.

    public async Task LinkOffer(Guid targetDeviceId)
    {
        var caller = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        if (!OnlineDevices.TryGetValue(targetDeviceId, out var connectionId))
            throw new HubException("link_target_offline");
        await Clients.Client(connectionId).SendAsync("LinkOffer",
            new { primaryDeviceId = caller }, Context.ConnectionAborted);
    }

    public async Task LinkConsent(Guid primaryDeviceId, string consentSig)
    {
        var caller = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        // An Ed25519 signature is 88 base64 chars; anything longer is not one.
        if (string.IsNullOrEmpty(consentSig) || consentSig.Length > 128)
            throw new HubException("Invalid consent");
        // The server-side half of consent: PUT device-list accepts this
        // device as a NEW companion of primaryDeviceId only while this
        // record exists (see DeviceListEndpoints.ConsentKey).
        cache.Set(DeviceListEndpoints.ConsentKey(caller, primaryDeviceId), true, TimeSpan.FromMinutes(10));
        if (!OnlineDevices.TryGetValue(primaryDeviceId, out var connectionId))
            throw new HubException("link_target_offline");
        await Clients.Client(connectionId).SendAsync("LinkConsent",
            new { deviceId = caller, consentSig }, Context.ConnectionAborted);
    }

    public Task AcknowledgeMessage(Guid senderId, Guid messageId)
        => queueService.AcknowledgeAsync(GetCallerDeviceId() ?? throw new HubException("Invalid device identity"),
            senderId, messageId, Context.ConnectionAborted);

    private async Task DeliverAsync(QueuedMessage message)
    {
        if (message.AcknowledgedAt != null) return;
        if (OnlineDevices.TryGetValue(message.RecipientId, out var connectionId))
            await Clients.Client(connectionId).SendAsync("ReceiveMessage", new
            {
                messageId = message.MessageId,
                senderId = message.SenderId,
                encryptedBody = Convert.ToBase64String(message.EncryptedBody),
                createdAt = message.CreatedAt,
                groupId = message.GroupId
            }, Context.ConnectionAborted);
        else
            await pushService.SendPushAsync(message.RecipientId);
    }

    private static byte[] DecodePayload(string payload)
    {
        if (string.IsNullOrWhiteSpace(payload) || payload.Length > 768 * 1024)
            throw new HubException("Invalid encrypted payload size");
        try { return Convert.FromBase64String(payload); }
        catch (FormatException) { throw new HubException("Invalid encrypted payload encoding"); }
    }
    /// <summary>
    /// Broadcasts a typing indicator to all other devices in a conversation.
    /// This is fire-and-forget — no persistence for typing signals since
    /// they are ephemeral and meaningless once stale.
    /// </summary>
    public async Task TypingIndicator(string conversationId)
    {
        var senderDeviceId = GetCallerDeviceId();
        if (senderDeviceId is null) return;

        if (!Guid.TryParse(conversationId, out var target))
            throw new HubException("Conversation must be a device or group UUID");
        var members = await db.GroupMembers.Where(m => m.GroupId == target)
            .Select(m => m.DeviceId).ToListAsync(Context.ConnectionAborted);
        if (members.Count > 0)
        {
            if (!members.Contains(senderDeviceId.Value))
                throw new HubException("Only group members may send typing indicators");
        }
        else
        {
            members.Add(target);
        }
        foreach (var recipient in members.Where(id => id != senderDeviceId.Value))
            if (OnlineDevices.TryGetValue(recipient, out var connectionId))
                await Clients.Client(connectionId).SendAsync("TypingIndicator", new
                {
                    senderId = senderDeviceId.Value,
                    conversationId
                }, Context.ConnectionAborted);
    }
    /// <summary>
    /// Relays WebRTC signaling messages (offer, answer, ICE candidates, hangup)
    /// between two devices for voice/video calls. These must be delivered in
    /// real-time — there is no offline queueing for call signals because a
    /// call to an offline device is meaningless.
    /// </summary>
    public Task CallSignal(Guid targetDeviceId, string signalType, string payload) =>
        RelayCallSignalAsync(targetDeviceId, signalType, payload, businessGroupId: null);

    /// <summary>
    /// H1: the business-call counterpart of <see cref="CallSignal"/>. A SEPARATE
    /// method rather than an optional 4th parameter on CallSignal, because a
    /// C# optional parameter is NOT honored by SignalR's argument binder — the
    /// first attempt at this (an optional Guid? on CallSignal) broke every
    /// existing 3-argument caller (deployed apps, calltype_core's
    /// SignalRClient.sendCallSignal, bots) with a server-side invocation
    /// error, caught by CallSignal_relays_to_online_target and
    /// Anonymous_call_signal_still_works_with_exactly_three_arguments. Kept as
    /// two methods so the old wire shape never has to guess about a missing
    /// argument.
    ///
    /// Both devices must be members of <paramref name="businessGroupId"/>,
    /// and — offers only — the organization's auditor must not be
    /// unavailable (KB2's call equivalent). The relayed event carries
    /// businessGroupId so the callee's UI knows a call is logged BEFORE
    /// answering.
    /// </summary>
    public async Task BusinessCallSignal(Guid targetDeviceId, string signalType, string payload, Guid businessGroupId)
    {
        var senderDeviceId = GetCallerDeviceId();
        if (senderDeviceId is null) return;

        await EnsureBusinessCallAllowedAsync(businessGroupId, senderDeviceId.Value, targetDeviceId, signalType);
        await RelayCallSignalAsync(targetDeviceId, signalType, payload, businessGroupId);
    }

    private async Task RelayCallSignalAsync(Guid targetDeviceId, string signalType, string payload, Guid? businessGroupId)
    {
        var senderDeviceId = GetCallerDeviceId();
        if (senderDeviceId is null) return;

        // P1: only the anonymous path (businessGroupId == null) is subject to
        // RequireBusinessConversations, and only on the offer — answer/ICE/
        // hangup must never interrupt a call that was already allowed to
        // start. BusinessCallSignal calls this with businessGroupId set, so
        // it's unaffected.
        if (businessGroupId is null && signalType == "offer"
            && !await communicationPolicy.IsAllowedAsync(senderDeviceId.Value, targetDeviceId, Context.ConnectionAborted))
            throw new HubException("business_conversation_required");

        if (OnlineDevices.TryGetValue(targetDeviceId, out var connectionId))
        {
            await Clients.Client(connectionId).SendAsync("CallSignal", new
            {
                senderId = senderDeviceId.Value,
                signalType,
                payload,
                businessGroupId
            });
        }
        else if (signalType == "offer")
        {
            // Target has no live connection. Tell the caller right away instead
            // of letting their UI ring into the void for the full 45 s timeout
            // (beta feedback). Only the initial offer is answered this way:
            // later signals of an established call are still dropped silently.
            // The original envelope is echoed back so the client can match the
            // reply to its callId and ignore it for any other call.
            // Privacy note: this reveals "not connected right now" to an
            // authenticated caller who already knows the device id — the same
            // fact the timeout would reveal, just sooner.
            await Clients.Caller.SendAsync("CallSignal", new
            {
                senderId = targetDeviceId,
                signalType = "unavailable",
                payload,
                businessGroupId
            });
        }
    }

    private record GroupMemberInfo(Guid DeviceId, string Role);

    /// <summary>
    /// Looks up a group's OrganizationId/IsEmergencyChannel/members, cached
    /// briefly. ICE candidates for one call are chatty (many signals for the
    /// same businessGroupId in a few seconds), so re-querying the DB for
    /// every one of them would be wasteful; 60s means a mid-call membership
    /// change takes effect from the NEXT call rather than never.
    /// </summary>
    private async Task<(Guid? OrganizationId, bool IsEmergency, List<GroupMemberInfo> Members)> GetBusinessGroupInfoAsync(Guid groupId)
    {
        var cacheKey = $"bizcall-group:{groupId}";
        if (cache.TryGetValue(cacheKey, out (Guid? OrganizationId, bool IsEmergency, List<GroupMemberInfo> Members) cached))
            return cached;

        var group = await db.Groups.AsNoTracking().Where(g => g.GroupId == groupId)
            .Select(g => new { g.OrganizationId, g.IsEmergencyChannel })
            .SingleOrDefaultAsync(Context.ConnectionAborted);
        if (group is null) return (null, false, []);

        var members = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Select(m => new GroupMemberInfo(m.DeviceId, m.Role)).ToListAsync(Context.ConnectionAborted);

        var result = (group.OrganizationId, group.IsEmergencyChannel, members);
        cache.Set(cacheKey, result, TimeSpan.FromSeconds(60));
        return result;
    }

    /// <summary>
    /// H1's hub gate for a business call. Throws (never relays) when either
    /// device isn't a member of a business group, and — on the offer only —
    /// when the organization's auditor is unavailable (AuditorLivenessService).
    /// The emergency channel is exempt from the liveness check per the owner
    /// decision: a drill/incident must not be blockable by archive backlog.
    /// </summary>
    private async Task EnsureBusinessCallAllowedAsync(Guid groupId, Guid senderDeviceId, Guid targetDeviceId, string signalType)
    {
        var (organizationId, isEmergency, members) = await GetBusinessGroupInfoAsync(groupId);
        if (organizationId is null)
            throw new HubException("not_a_business_member");

        var memberIds = members.Select(m => m.DeviceId).ToHashSet();
        if (!memberIds.Contains(senderDeviceId) || !memberIds.Contains(targetDeviceId))
            throw new HubException("not_a_business_member");

        if (signalType != "offer" || isEmergency) return;

        // AuditorLivenessService.IsAliveAsync takes the ORGANIZATION id (it
        // looks up the org's AuditorDeviceId itself) — same call shape as
        // SendReliableGroupMessage's W2-F gate above.
        if (!await auditorLiveness.IsAliveAsync(organizationId.Value, Context.ConnectionAborted))
            throw new HubException("auditor_unavailable");
    }

    // -----------------------------------------------------------------------
    // Channels (public one-way broadcast — plaintext by design, see Channel.cs)
    // -----------------------------------------------------------------------

    /// <summary>SignalR group that receives the events of one channel.</summary>
    internal static string ChannelGroup(Guid channelId) => $"channel:{channelId}";

    /// <summary>
    /// Lets ChannelService decide who needs a push without exposing the map.
    /// </summary>
    internal static bool IsOnline(Guid deviceId) => OnlineDevices.ContainsKey(deviceId);

    /// <summary>
    /// Lets server-initiated pushes outside a hub method (e.g. EmergencyEndpoints
    /// starting a drill) reach an online device the same way CallSignal/TypingIndicator
    /// do, without exposing the OnlineDevices dictionary itself.
    /// </summary>
    internal static bool TryGetConnectionId(Guid deviceId, out string connectionId) =>
        OnlineDevices.TryGetValue(deviceId, out connectionId!);

    /// <summary>
    /// Subscribes THIS connection to every channel the caller follows, owns or
    /// administers. Group membership belongs to a connection, not a device, and
    /// REST endpoints cannot reach the connection — so the client calls this
    /// after every (re)connect and again after following a channel.
    /// Returns the joined channel ids (the caller's own data, nobody else's).
    /// </summary>
    public async Task<List<Guid>> JoinChannels()
    {
        var deviceId = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");

        var channelIds = await db.Channels
            .Where(c => c.DeletedAt == null && (
                c.Followers.Any(f => f.DeviceId == deviceId) ||
                c.Admins.Any(a => a.DeviceId == deviceId) ||
                db.AccountDevices.Any(ad => ad.DeviceId == deviceId && ad.AccountId == c.OwnerAccountId)))
            .Select(c => c.ChannelId)
            .ToListAsync(Context.ConnectionAborted);

        foreach (var channelId in channelIds)
            await Groups.AddToGroupAsync(Context.ConnectionId, ChannelGroup(channelId), Context.ConnectionAborted);

        return channelIds;
    }

    /// <summary>
    /// Counterpart for unfollow: DELETE /channels/{id}/follow cannot touch the
    /// connection, so the client leaves the group itself. No membership check —
    /// leaving a group you are not in is a no-op. A client that "forgets" to
    /// leave keeps receiving posts until it reconnects; they are public anyway.
    /// </summary>
    public Task LeaveChannel(Guid channelId) =>
        Groups.RemoveFromGroupAsync(Context.ConnectionId, ChannelGroup(channelId), Context.ConnectionAborted);

    /// <summary>
    /// Extracts the caller's DeviceId from the JWT "sub" claim.
    /// Returns null if the claim is missing or malformed.
    /// With [Authorize] on the hub, the claim should always be present,
    /// but defensive parsing avoids a hard crash on malformed tokens.
    /// </summary>
    private Guid? GetCallerDeviceId()
    {
        var deviceId = GetDeviceId();
        return deviceId != Guid.Empty ? deviceId : null;
    }

    /// <summary>
    /// Reads the DeviceId from the authenticated user's JWT claims.
    /// Returns Guid.Empty if the claim is missing (should not happen
    /// under [Authorize], but defensive coding is cheap insurance).
    /// </summary>
    private Guid GetDeviceId()
    {
        // Try the mapped ClaimTypes.NameIdentifier first (ASP.NET Core maps
        // "sub" to this by default), then fall back to the raw "sub" claim
        // in case the mapping is disabled.
        var sub = Context.User?.FindFirst(ClaimTypes.NameIdentifier)?.Value
               ?? Context.User?.FindFirst("sub")?.Value;

        return Guid.TryParse(sub, out var id) ? id : Guid.Empty;
    }
}
