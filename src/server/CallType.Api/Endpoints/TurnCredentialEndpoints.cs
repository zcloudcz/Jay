// ---------------------------------------------------------------------------
// TurnCredentialEndpoints.cs — Time-limited TURN credential API
// ---------------------------------------------------------------------------
// WebRTC requires TURN servers for NAT traversal when peer-to-peer connections
// fail. This endpoint issues short-lived credentials that the client passes to
// the ICE agent. The credentials are HMAC-based and verified by the DeskShare.Turn
// server without any database lookup — purely cryptographic verification.
//
// Security: deviceId is required to bind the credential to a specific device.
// In production this should be authenticated (JWT), but for now the deviceId
// is self-reported. The TURN TTL (default 24h) limits abuse window.
// ---------------------------------------------------------------------------

using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class TurnCredentialEndpoints
{
    /// <summary>
    /// Registers the TURN credential route on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapTurnCredentialEndpoints(this WebApplication app)
    {
        app.MapGet("/turn/credentials", GetCredentials);
        return app;
    }

    // -----------------------------------------------------------------------
    // GET /turn/credentials?deviceId=xxx — Get time-limited TURN credentials
    // -----------------------------------------------------------------------
    private static IResult GetCredentials(
        Guid? deviceId,
        TurnCredentialService turnService)
    {
        // deviceId is mandatory — we embed it in the TURN username so the
        // server can correlate ICE sessions to specific devices for debugging.
        if (deviceId is null || deviceId == Guid.Empty)
            return Results.BadRequest(new { error = "deviceId query parameter is required." });

        var credentials = turnService.Generate(deviceId.Value, DateTimeOffset.UtcNow);

        return Results.Ok(credentials);
    }
}
