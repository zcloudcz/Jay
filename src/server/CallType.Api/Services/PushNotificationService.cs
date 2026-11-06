// ---------------------------------------------------------------------------
// PushNotificationService.cs - Push notification delivery for offline devices
// ---------------------------------------------------------------------------
// When a message is queued for an offline device (or a call offer finds the
// callee offline, or a channel posts), this service wakes the device through
// its registered provider: FCM (Android), APNs (iOS) or Web Push (browsers).
// The push is a VISIBLE but generic notification ("New message"): the server
// has no plaintext because of E2E encryption, and names would leak metadata
// to Apple/Google (spec 2026-11-06-notifications, N2).
//
// The provider senders (IPushSender) own HTTP and payload format; this
// service owns the device lookup, dispatch by Device.PushPlatform and
// clearing of tokens the provider declared dead.
//
// Registered as a singleton: it holds the per-channel throttle and uses
// IServiceScopeFactory for short-lived DbContext scopes, avoiding the
// scoped-in-singleton anti-pattern.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

/// <summary>
/// "At most one push per channel per window" (channels plan §3). Split out of
/// <see cref="PushNotificationService"/> and given an explicit clock so the
/// rule can be unit tested without a database, FCM or real waiting.
/// </summary>
internal sealed class ChannelPushThrottle
{
    // ponytail: in-memory, per-process state. Correct only because the API runs
    // as exactly ONE App Service instance (CLAUDE.md design decision 6); a
    // restart merely allows one extra push. Move to a shared store (DB column /
    // Redis) together with the SignalR backplane if the API is ever scaled out.
    // Grows by one small entry per channel that ever posted, bounded by the
    // number of channels, so no eviction.
    private readonly ConcurrentDictionary<Guid, DateTimeOffset> _lastPush = new();

    /// <summary>True = the caller may push now (and the window restarts).</summary>
    public bool TryAcquire(Guid channelId, DateTimeOffset now, TimeSpan window)
    {
        // Compare-and-swap loop instead of a lock: two posts published at the
        // same moment must not BOTH see "window elapsed" and both push.
        while (true)
        {
            if (!_lastPush.TryGetValue(channelId, out var last))
            {
                if (_lastPush.TryAdd(channelId, now)) return true;
            }
            else
            {
                if (now - last < window) return false;
                if (_lastPush.TryUpdate(channelId, now, last)) return true;
            }
        }
    }
}

public class PushNotificationService
{
    private readonly ChannelPushThrottle _channelThrottle = new();
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly Dictionary<string, IPushSender> _senders;
    private readonly ILogger<PushNotificationService> _logger;

    public PushNotificationService(
        IServiceScopeFactory scopeFactory,
        IEnumerable<IPushSender> senders,
        ILogger<PushNotificationService> logger)
    {
        _scopeFactory = scopeFactory;
        _senders = senders.ToDictionary(s => s.Platform, StringComparer.Ordinal);
        _logger = logger;
    }

    /// <summary>
    /// Sends one push to a device if it has a registered push token.
    /// </summary>
    /// <remarks>
    /// Never throws: push delivery failures are logged and swallowed. Push is
    /// a best-effort optimization; the client still gets its messages on the
    /// next connect via the store-and-forward queue. Virtual so hub tests can
    /// record who would be woken without any provider.
    /// </remarks>
    public virtual async Task SendPushAsync(Guid recipientDeviceId, PushNotification notification)
    {
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

            var device = await db.Devices.AsNoTracking()
                .Where(d => d.DeviceId == recipientDeviceId && d.PushToken != null)
                .Select(d => new { d.PushToken, d.PushPlatform, d.PushLocale })
                .FirstOrDefaultAsync();
            if (device is null) return;

            await DispatchAsync(db, recipientDeviceId, device.PushToken!, device.PushPlatform, device.PushLocale,
                notification);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Push to device {DeviceId} failed", recipientDeviceId);
        }
    }

    /// <summary>
    /// Wakes the offline followers of a channel after a new post: one generic
    /// "channel_post" push each (K04: no channel name, no text; the client
    /// pulls GET /channels/mine itself). Throttled per channel so a chatty
    /// channel cannot spam lock screens.
    /// </summary>
    /// <param name="isOnline">
    /// Supplied by the caller (the hub's connection map) so this service does
    /// not depend on the hub. Online followers already got the SignalR event.
    /// </param>
    public async Task SendChannelPostPushAsync(Guid channelId, TimeSpan throttleWindow, Func<Guid, bool> isOnline)
    {
        if (!_channelThrottle.TryAcquire(channelId, DateTimeOffset.UtcNow, throttleWindow)) return;

        try
        {
            using var scope = _scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

            // ONE joined query returning only what a send needs, for every
            // follower that can be pushed at all, not a device lookup per follower.
            var targets = await db.ChannelFollowers
                .Where(f => f.ChannelId == channelId)
                .Join(db.Devices.Where(d => d.PushToken != null),
                    f => f.DeviceId, d => d.DeviceId,
                    (f, d) => new { d.DeviceId, Token = d.PushToken!, d.PushPlatform, d.PushLocale })
                .ToListAsync();

            var notification = PushNotification.ForChannelPost(channelId);
            // ponytail: sequential sends on one DbContext. Fine for beta-sized
            // channels and it runs in the background; switch to FCM topics (one
            // call per post) before channels reach tens of thousands of followers.
            foreach (var target in targets)
                if (!isOnline(target.DeviceId))
                    await DispatchAsync(db, target.DeviceId, target.Token, target.PushPlatform, target.PushLocale,
                        notification);
        }
        catch (Exception ex)
        {
            // The caller does not await this task (fire-and-forget), so an
            // escaping exception would go unobserved. Push stays best-effort.
            _logger.LogWarning(ex, "Channel post push for channel {ChannelId} failed", channelId);
        }
    }

    private async Task DispatchAsync(AppDbContext db, Guid deviceId, string token, string? platform, string? locale,
        PushNotification notification)
    {
        if (platform is null || !_senders.TryGetValue(platform, out var sender))
        {
            _logger.LogWarning("Unknown push platform '{Platform}' for device {DeviceId}", platform, deviceId);
            return;
        }

        // No cancellation token on purpose: the hub call that triggered the
        // push may end (caller disconnects) while the push is still useful.
        var result = await sender.SendAsync(token, notification, locale, CancellationToken.None);
        if (result != PushSendResult.TokenInvalid) return;

        // Provider confirmed the token is dead. Clear only the exact token we
        // just used: if it was rotated mid-request, the new token (already
        // saved by the client's re-registration) must survive this update.
        _logger.LogInformation("{Platform} token for device {DeviceId} is no longer valid, clearing it",
            platform, deviceId);
        await db.Devices
            .Where(d => d.DeviceId == deviceId && d.PushToken == token)
            .ExecuteUpdateAsync(s => s
                .SetProperty(d => d.PushToken, (string?)null)
                .SetProperty(d => d.PushPlatform, (string?)null)
                .SetProperty(d => d.PushLocale, (string?)null));
    }
}
