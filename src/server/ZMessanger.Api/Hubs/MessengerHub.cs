// ---------------------------------------------------------------------------
// MessengerHub.cs — SignalR hub for real-time message relay
// ---------------------------------------------------------------------------
// The hub is the real-time transport layer. It tracks which devices are
// connected (by mapping DeviceId → ConnectionId) and routes encrypted
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
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using Microsoft.AspNetCore.SignalR;
using ZMessanger.Api.Services;

namespace ZMessanger.Api.Hubs;

public class MessengerHub(MessageQueueService queueService) : Hub
{
    // Maps DeviceId → ConnectionId for all currently connected devices.
    // Static because SignalR creates a new Hub instance per invocation,
    // but we need the connection map to survive across all instances.
    private static readonly ConcurrentDictionary<Guid, string> OnlineDevices = new();

    public override async Task OnConnectedAsync()
    {
        // The client must pass its DeviceId as a query string parameter
        // when establishing the SignalR connection (e.g. /hub?deviceId=xxx).
        var deviceIdStr = Context.GetHttpContext()?.Request.Query["deviceId"].ToString();

        if (Guid.TryParse(deviceIdStr, out var deviceId))
        {
            // If the same device reconnects (e.g. after a network blip),
            // the old connection ID is overwritten — only the latest
            // connection for a device is considered active.
            OnlineDevices[deviceId] = Context.ConnectionId;

            // Deliver any messages that accumulated while the device was offline.
            // This runs on connect so the client doesn't need a separate "fetch
            // queued messages" API call — it just opens the hub and gets everything.
            var queued = await queueService.DequeueAsync(deviceId);

            foreach (var msg in queued)
            {
                await Clients.Caller.SendAsync("ReceiveMessage", new
                {
                    senderId = msg.SenderId,
                    encryptedBody = Convert.ToBase64String(msg.EncryptedBody),
                    createdAt = msg.CreatedAt
                });
            }
        }

        await base.OnConnectedAsync();
    }

    public override Task OnDisconnectedAsync(Exception? exception)
    {
        var deviceIdStr = Context.GetHttpContext()?.Request.Query["deviceId"].ToString();

        if (Guid.TryParse(deviceIdStr, out var deviceId))
        {
            // Only remove if the stored connection ID matches ours — prevents
            // a stale disconnect from removing a newer reconnection's entry.
            OnlineDevices.TryRemove(new KeyValuePair<Guid, string>(deviceId, Context.ConnectionId));
        }

        return base.OnDisconnectedAsync(exception);
    }

    /// <summary>
    /// Sends an encrypted message to a specific device. If the recipient is
    /// online, the message is delivered immediately via SignalR. If offline,
    /// it is queued for later delivery.
    /// </summary>
    public async Task SendMessage(Guid recipientDeviceId, string encryptedBodyBase64)
    {
        var senderDeviceId = GetCallerDeviceId();
        if (senderDeviceId is null) return;

        var encryptedBody = Convert.FromBase64String(encryptedBodyBase64);

        if (OnlineDevices.TryGetValue(recipientDeviceId, out var connectionId))
        {
            // Recipient is online — deliver directly. This avoids a DB round-trip
            // and gives sub-second latency for the common case.
            await Clients.Client(connectionId).SendAsync("ReceiveMessage", new
            {
                senderId = senderDeviceId.Value,
                encryptedBody = encryptedBodyBase64,
                createdAt = DateTimeOffset.UtcNow
            });
        }
        else
        {
            // Recipient is offline — store for later delivery.
            await queueService.EnqueueAsync(recipientDeviceId, senderDeviceId.Value, encryptedBody);
        }
    }

    /// <summary>
    /// Sends an encrypted group message. The caller provides a dictionary of
    /// DeviceId → encrypted payload (each device gets a uniquely encrypted copy
    /// because E2E encryption uses per-device keys).
    /// </summary>
    public async Task SendGroupMessage(Guid groupId, Dictionary<Guid, string> encryptedPayloads)
    {
        var senderDeviceId = GetCallerDeviceId();
        if (senderDeviceId is null) return;

        foreach (var (deviceId, encryptedBodyBase64) in encryptedPayloads)
        {
            // Skip sending to ourselves — the sender's client already has
            // the plaintext and doesn't need an echo.
            if (deviceId == senderDeviceId.Value)
                continue;

            if (OnlineDevices.TryGetValue(deviceId, out var connectionId))
            {
                await Clients.Client(connectionId).SendAsync("ReceiveMessage", new
                {
                    senderId = senderDeviceId.Value,
                    encryptedBody = encryptedBodyBase64,
                    createdAt = DateTimeOffset.UtcNow,
                    groupId
                });
            }
            else
            {
                var encryptedBody = Convert.FromBase64String(encryptedBodyBase64);
                await queueService.EnqueueAsync(deviceId, senderDeviceId.Value, encryptedBody);
            }
        }
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

        // Broadcast to all connected clients except the sender.
        // In a production system this would be scoped to conversation
        // participants, but that requires group membership lookup.
        // For now, use Others — the client filters by conversationId.
        await Clients.Others.SendAsync("TypingIndicator", new
        {
            senderId = senderDeviceId.Value,
            conversationId
        });
    }

    /// <summary>
    /// Relays WebRTC signaling messages (offer, answer, ICE candidates, hangup)
    /// between two devices for voice/video calls. These must be delivered in
    /// real-time — there is no offline queueing for call signals because a
    /// call to an offline device is meaningless.
    /// </summary>
    public async Task CallSignal(Guid targetDeviceId, string signalType, string payload)
    {
        var senderDeviceId = GetCallerDeviceId();
        if (senderDeviceId is null) return;

        if (OnlineDevices.TryGetValue(targetDeviceId, out var connectionId))
        {
            await Clients.Client(connectionId).SendAsync("CallSignal", new
            {
                senderId = senderDeviceId.Value,
                signalType,
                payload
            });
        }
        // If the target is offline, the signal is silently dropped.
        // The caller's UI should handle "no answer" via a timeout.
    }

    /// <summary>
    /// Extracts the caller's DeviceId from the connection query string.
    /// Returns null if the query parameter is missing or malformed.
    /// </summary>
    private Guid? GetCallerDeviceId()
    {
        var deviceIdStr = Context.GetHttpContext()?.Request.Query["deviceId"].ToString();
        return Guid.TryParse(deviceIdStr, out var deviceId) ? deviceId : null;
    }
}
