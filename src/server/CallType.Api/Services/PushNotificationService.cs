// ---------------------------------------------------------------------------
// PushNotificationService.cs — Push notification delivery for offline devices
// ---------------------------------------------------------------------------
// When a message is queued for an offline device, this service attempts to
// wake it via platform-specific push notifications (FCM for Android/Web,
// APNs for iOS). The push is data-only (no notification body) so the client
// controls how to display it — the server knows nothing about message content
// because of E2E encryption.
//
// Uses the FCM HTTP v1 API (https://fcm.googleapis.com/v1/.../messages:send)
// authenticated with OAuth2 access tokens from FcmTokenProvider. The legacy
// server-key API this service originally targeted was shut down by Google in
// June 2024 and must not be used.
//
// The service is registered as a singleton because it is stateless — it uses
// IHttpClientFactory for pooled connections and IServiceScopeFactory to create
// short-lived DbContext scopes for device lookups, avoiding the
// scoped-in-singleton anti-pattern.
// ---------------------------------------------------------------------------

using System.Net;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

/// <summary>
/// Outcome of evaluating an FCM HTTP v1 response. Kept separate from the
/// token/DB plumbing so the response-parsing rules from K04 — a bare 404 does
/// NOT prove the token is dead, only a 404 carrying the FCM "UNREGISTERED"
/// error code does — can be unit tested without a database or real HTTP call.
/// </summary>
internal enum FcmSendOutcome
{
    /// <summary>Message accepted, or a transient/unknown failure — token is untouched.</summary>
    Ok,

    /// <summary>Provider confirmed the token is dead (404 + errorCode "UNREGISTERED").</summary>
    TokenUnregistered,
}

/// <summary>
/// Pure response-evaluation logic for FCM HTTP v1, split out of
/// <see cref="PushNotificationService"/> so it can be unit tested directly
/// against canned status codes/bodies instead of a live endpoint.
/// </summary>
internal static class FcmResponseEvaluator
{
    /// <summary>
    /// FCM HTTP v1 error responses look like:
    /// { "error": { "code": 404, "status": "NOT_FOUND",
    ///   "details": [{ "@type": "...FcmError", "errorCode": "UNREGISTERED" }] } }
    /// A 404 without that specific errorCode (e.g. a malformed request, or a
    /// generic "not found") must NOT be treated as proof the token is dead.
    /// </summary>
    public static FcmSendOutcome Evaluate(HttpStatusCode statusCode, string responseBody)
    {
        if (statusCode != HttpStatusCode.NotFound)
            return FcmSendOutcome.Ok;

        try
        {
            using var doc = JsonDocument.Parse(responseBody);
            if (doc.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("details", out var details) &&
                details.ValueKind == JsonValueKind.Array)
            {
                foreach (var detail in details.EnumerateArray())
                {
                    if (detail.TryGetProperty("errorCode", out var code) &&
                        code.GetString() == "UNREGISTERED")
                    {
                        return FcmSendOutcome.TokenUnregistered;
                    }
                }
            }
        }
        catch (JsonException)
        {
            // Unparseable body — treat like any other non-UNREGISTERED failure.
        }

        return FcmSendOutcome.Ok;
    }
}

public class PushNotificationService
{
    private readonly IHttpClientFactory _httpFactory;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly FcmTokenProvider _fcmTokens;
    private readonly ILogger<PushNotificationService> _logger;

    public PushNotificationService(
        IHttpClientFactory httpFactory,
        IServiceScopeFactory scopeFactory,
        FcmTokenProvider fcmTokens,
        ILogger<PushNotificationService> logger)
    {
        _httpFactory = httpFactory;
        _scopeFactory = scopeFactory;
        _fcmTokens = fcmTokens;
        _logger = logger;
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
                await SendFcmAsync(db, recipientDeviceId, device.PushToken);
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
    /// Sends a data-only FCM message via the HTTP v1 API.
    /// Data-only (no "notification" block) means the message is always delivered
    /// to the app's message handler — even in the foreground. The client decides
    /// whether and how to show a local notification.
    /// </summary>
    private async Task SendFcmAsync(AppDbContext db, Guid deviceId, string token)
    {
        if (!_fcmTokens.IsConfigured)
        {
            _logger.LogWarning(
                "FCM service account not configured (Push:FcmServiceAccountJson), skipping push");
            return;
        }

        try
        {
            var accessToken = await _fcmTokens.GetAccessTokenAsync();

            var client = _httpFactory.CreateClient();
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"https://fcm.googleapis.com/v1/projects/{_fcmTokens.ProjectId}/messages:send");
            request.Headers.Authorization = new("Bearer", accessToken);

            // Data-only message — no "notification" block. This ensures:
            // 1. The app always receives the message in its handler (not the system tray)
            // 2. The client controls display, which matters for E2E encrypted content
            //    where the server has no plaintext to put in a notification body.
            request.Content = JsonContent.Create(new
            {
                message = new
                {
                    token,
                    data = new { type = "new_message" }
                }
            });

            using var response = await client.SendAsync(request);

            if (!response.IsSuccessStatusCode)
            {
                // Never log the raw provider body — FCM error messages have
                // echoed back request details in the past, and we must not
                // risk leaking the token or payload into logs (K04).
                var body = await response.Content.ReadAsStringAsync();
                var outcome = FcmResponseEvaluator.Evaluate(response.StatusCode, body);

                if (outcome == FcmSendOutcome.TokenUnregistered)
                {
                    // Provider confirmed the token is dead. Clear only the exact
                    // token we just used — if it was rotated mid-request, the new
                    // token (already saved by the client's re-registration) must
                    // survive this delete.
                    _logger.LogInformation(
                        "FCM token for device {DeviceId} is unregistered, clearing it",
                        deviceId);

                    await db.Devices
                        .Where(d => d.DeviceId == deviceId && d.PushToken == token)
                        .ExecuteUpdateAsync(s => s
                            .SetProperty(d => d.PushToken, (string?)null)
                            .SetProperty(d => d.PushPlatform, (string?)null));
                }
                else
                {
                    _logger.LogWarning(
                        "FCM push failed with status {StatusCode}",
                        (int)response.StatusCode);
                }
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
