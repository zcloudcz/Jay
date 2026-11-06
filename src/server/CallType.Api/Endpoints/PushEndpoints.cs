// ---------------------------------------------------------------------------
// PushEndpoints.cs - Public push configuration for clients
// ---------------------------------------------------------------------------
// GET /push/webpush-key: the browser needs the VAPID public key BEFORE it can
// subscribe (PushManager.subscribe applicationServerKey). Anonymous because
// the key is public by definition and the web app may fetch it before login.
// 404 tells the client Web Push is not configured on this server.
// ---------------------------------------------------------------------------

using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class PushEndpoints
{
    public static WebApplication MapPushEndpoints(this WebApplication app)
    {
        app.MapGet("/push/webpush-key", (WebPushSender webPush) => webPush.PublicKey is { } key
                ? Results.Ok(new WebPushKeyResponse(key))
                : Results.NotFound(new { error = "webpush_not_configured" }))
            .AllowAnonymous()
            .RequireRateLimiting("api");
        return app;
    }
}

public record WebPushKeyResponse(string PublicKey);
