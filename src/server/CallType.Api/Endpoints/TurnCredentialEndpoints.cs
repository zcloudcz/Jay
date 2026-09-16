// ---------------------------------------------------------------------------
// TurnCredentialEndpoints.cs — Time-limited TURN credential API
// ---------------------------------------------------------------------------
// WebRTC requires TURN servers for NAT traversal when peer-to-peer connections
// fail. This endpoint issues short-lived credentials that the client passes to
// the ICE agent. The issuer is pluggable (ITurnCredentialProvider): either the
// self-hosted HMAC scheme (coturn / DeskShare.Turn) or Cloudflare TURN. The
// response shape is identical so the Flutter client does not care which.
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
        // TURN credentials require authentication — prevents anonymous clients
        // from using our TURN server as an open relay.
        app.MapGet("/turn/credentials", GetCredentials).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------------
    // GET /turn/credentials?deviceId=xxx — Get time-limited TURN credentials
    // -----------------------------------------------------------------------
    private static async Task<IResult> GetCredentials(
        Guid? deviceId,
        ITurnCredentialProvider turnProvider,
        CancellationToken cancellationToken)
    {
        // deviceId is mandatory — we embed it in the TURN username so the
        // server can correlate ICE sessions to specific devices for debugging.
        if (deviceId is null || deviceId == Guid.Empty)
            return Results.BadRequest(new { error = "deviceId query parameter is required." });

        TurnIceCredentials credentials;
        try
        {
            credentials = await turnProvider.IssueAsync(deviceId.Value, cancellationToken);
        }
        catch (TurnUnavailableException)
        {
            // Client falls back to STUN-only / direct ICE; calls behind symmetric
            // NAT will fail, but signaling and chat are unaffected.
            return Results.Json(new { error = "TURN credentials are temporarily unavailable." },
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }

        return Results.Ok(new {
            credentials.Username, credentials.Credential, credentials.TtlSeconds,
            credentials.Urls, credentials.StunUrls
        });
    }
}
