// ---------------------------------------------------------------------------
// IPushNotificationService.cs — push for messages and channels (frozen in X0)
// ---------------------------------------------------------------------------
// Contract from docs/superpowers/plans/2026-09-29-gap-notifications.md §4.3,
// narrowed by gap-contracts K5: call pushes do NOT live here — they go through
// ICallPushSender (stream C calls it, stream N implements it). This interface
// is only for message and channel wake-ups.
//
// Why an interface at all: MessengerHub and ChannelService call it, stream N
// replaces the implementation (dispatcher, APNs, coalescing) in wave 1 while
// stream C owns the hub; tests swap in a double without mocking the DB.
//
// X0 implementation = PushNotificationService with today's behaviour
// (SendMessagePushAsync -> SendPushAsync, ScheduleUnackedPushCheck no-op).
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

public interface IPushNotificationService
{
    /// <summary>Backwards compatible wake-up push without any hint.</summary>
    Task SendPushAsync(Guid recipientDeviceId);

    /// <summary>
    /// The recipient of a message is offline. Must never throw. Contract (N1):
    /// returns immediately after handing the push to a dispatcher. X0's stub
    /// still awaits the FCM call like the code before it — stream N removes
    /// that sequential wait.
    /// </summary>
    Task SendMessagePushAsync(Guid recipientDeviceId, Guid senderDeviceId, Guid messageId, Guid? groupId);

    /// <summary>
    /// The recipient was online and got the message over SignalR. If no
    /// AcknowledgeMessage arrives within Push:UnackedRepushSeconds, a push is
    /// sent anyway (a "zombie" connection that still looks alive). Must not
    /// block the caller. X0 stub: no-op.
    /// </summary>
    void ScheduleUnackedPushCheck(Guid recipientDeviceId, Guid senderDeviceId, Guid messageId, Guid? groupId);

    /// <summary>
    /// Wakes the offline followers of a channel after a new post, throttled per
    /// channel. <paramref name="isOnline"/> comes from the hub's connection map.
    /// </summary>
    Task SendChannelPostPushAsync(Guid channelId, TimeSpan throttleWindow, Func<Guid, bool> isOnline);
}
