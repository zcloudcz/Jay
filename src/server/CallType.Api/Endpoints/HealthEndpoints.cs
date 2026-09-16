// ---------------------------------------------------------------------------
// HealthEndpoints.cs — liveness and readiness probes
// ---------------------------------------------------------------------------
// /health        — liveness. Always 200 while the process is up, even if
//                  PostgreSQL or Blob storage are down. Orchestrators must
//                  not restart the process for a downstream outage it can't
//                  fix by restarting.
// /health/ready  — readiness (K05). 200 only when PostgreSQL and the backup
//                  Blob container are both reachable; 503 otherwise. Body is
//                  a fixed two-shape JSON — no addresses, no exceptions.
// Both are AllowAnonymous: orchestrators probe without credentials.
// ---------------------------------------------------------------------------

using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class HealthEndpoints
{
    public static void MapHealthEndpoints(this WebApplication app)
    {
        app.MapGet("/health", () => Results.Ok(new { status = "healthy" }))
            .AllowAnonymous();

        app.MapGet("/health/ready", async (ReadinessService readiness, CancellationToken ct) =>
        {
            var ready = await readiness.IsReadyAsync(ct);
            return ready
                ? Results.Ok(new { status = "ready" })
                : Results.Json(new { status = "not_ready" }, statusCode: StatusCodes.Status503ServiceUnavailable);
        }).AllowAnonymous();
    }
}
