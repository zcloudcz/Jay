// ---------------------------------------------------------------------------
// PushNotificationService.cs — Push notification delivery for offline devices
// ---------------------------------------------------------------------------
// When a message is queued for an offline device, this service attempts to
// wake it via platform-specific push notifications (FCM for Android/Web,
// APNs for iOS). The push is data-only (no notification body) so the client
// controls how to display it — the server knows nothing about message content
// because of E2E encryption.
//
// Uses the FCM legacy HTTP API for simplicity in the MVP. The legacy API
// requires only a server key (no OAuth2 service account), which keeps
// deployment simple. Can be upgraded to FCM HTTP v1 later for features
// like topic messaging and analytics.
//
// The service is registered as a singleton because it is stateless — it reads
// config once and uses IHttpClientFactory for pooled connections. It takes
// IServiceScopeFactory to create short-lived DbContext scopes for device
// lookups, avoiding the scoped-in-singleton anti-pattern.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

public class PushNotificationService
{
    private readonly IHttpClientFactory _httpFactory;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<PushNotificationService> _logger;
    private readonly string? _fcmServerKey;

    public PushNotificationService(
        IHttpClientFactory httpFactory,
        IServiceScopeFactory scopeFactory,
        IConfiguration config,
        ILogger<PushNotificationService> logger)
    {
        _httpFactory = httpFactory;
        _scopeFactory = scopeFactory;
        _logger = logger;
        _fcmServerKey = config["Push:FcmServerKey"];
    }

    /// <summary>
    /// Sends a push notification to a device if it has a registered push token.
    /// Looks up the device's push token and platform from the database, then
    /// dispatches to the appropriate platform-specific sender.
    /// </summary>
    /// <remarks>
    /// This is fire-and-forget from the caller's perspective — push delivery
    /// failures are logged but never propagated. Push is a best-effort
    /// optimization; the client will still get messages on next connect
    /// via the store-and-forward queue.
    /// </remarks>
    public async Task SendPushAsync(Guid recipientDeviceId)
    {
        using var scope = _scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == recipientDeviceId);
        if (device?.PushToken is null) return;

        switch (device.PushPlatform)
        {
            case "fcm":
                await SendFcmAsync(device.PushToken);
                break;
            case "apns":
                // APNs HTTP/2 push requires an Apple auth key (.p8) and team ID.
                // Not implemented yet — will be added when the iOS build is ready.
                // For now just log so we can track how many iOS devices are missing push.
                _logger.LogInformation(
                    "APNs push to device {DeviceId} skipped (not yet implemented)",
                    recipientDeviceId);
                break;
            default:
                _logger.LogWarning(
                    "Unknown push platform '{Platform}' for device {DeviceId}",
                    device.PushPlatform, recipientDeviceId);
                break;
        }
    }

    /// <summary>
    /// Sends a data-only FCM message via the legacy HTTP API.
    /// Data-only (no "notification" block) means the message is always delivered
    /// to the app's message handler — even in the foreground. The client decides
    /// whether and how to show a local notification.
    /// </summary>
    private async Task SendFcmAsync(string token)
    {
        if (string.IsNullOrEmpty(_fcmServerKey))
        {
            _logger.LogWarning("FCM server key not configured (Push:FcmServerKey), skipping push");
            return;
        }

        try
        {
            var client = _httpFactory.CreateClient();
            client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", $"key={_fcmServerKey}");

            // Data-only message — no "notification" block. This ensures:
            // 1. The app always receives the message in its handler (not the system tray)
            // 2. The client controls display, which matters for E2E encrypted content
            //    where the server has no plaintext to put in a notification body.
            var payload = new
            {
                to = token,
                data = new { type = "new_message" }
            };

            var response = await client.PostAsJsonAsync(
                "https://fcm.googleapis.com/fcm/send",
                payload);

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning(
                    "FCM push failed with status {StatusCode}",
                    response.StatusCode);
            }
        }
        catch (Exception ex)
        {
            // Push is best-effort — never let a push failure crash the message flow.
            // The message is already queued; the client will get it on next connect.
            _logger.LogWarning(ex, "FCM push failed with exception");
        }
    }
}
