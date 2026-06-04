// ---------------------------------------------------------------------------
// AuthEndpoints.cs — Device authentication via JWT tokens
// ---------------------------------------------------------------------------
// Devices authenticate by presenting their device secret (received once at
// registration) to obtain a short-lived JWT. The JWT is then used as a Bearer
// token for all subsequent API calls and SignalR connections.
//
// Two endpoints:
//   POST /auth/token   — Exchange device secret for a JWT (login)
//   POST /auth/refresh — Exchange a valid/recently-expired JWT for a new one
//
// The device secret flow is intentionally simple: the secret is a 32-byte
// random value issued at registration, and verification is a constant-time
// SHA-256 comparison. No password stretching (Argon2/bcrypt) is needed because
// the secret is already high-entropy (256 bits) — brute-force is infeasible.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class AuthEndpoints
{
    /// <summary>
    /// Registers all auth-related routes on the application pipeline.
    /// Both endpoints are public (no [Authorize]) — they ARE the auth mechanism.
    /// </summary>
    public static WebApplication MapAuthEndpoints(this WebApplication app)
    {
        // Both auth endpoints are public — they are the authentication mechanism
        // itself. The device proves identity via device secret (token) or existing
        // JWT (refresh), not via the Authorization header middleware.
        // Stricter rate limit on auth endpoints — 10 req/min to slow down
        // credential brute-force attempts against the device secret.
        app.MapPost("/auth/token", GetToken).AllowAnonymous().RequireRateLimiting("auth");
        app.MapPost("/auth/refresh", RefreshToken).AllowAnonymous().RequireRateLimiting("auth");
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /auth/token — Exchange device secret for JWT
    // -----------------------------------------------------------------------
    private static async Task<IResult> GetToken(
        TokenRequest request,
        AppDbContext db,
        JwtService jwtService,
        CancellationToken ct)
    {
        if (request.DeviceId == Guid.Empty || string.IsNullOrWhiteSpace(request.DeviceSecret))
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);

        // Decode the base64-encoded secret from the client.
        byte[] secretBytes;
        try
        {
            secretBytes = Convert.FromBase64String(request.DeviceSecret);
        }
        catch (FormatException)
        {
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);
        }

        var device = await db.Devices
            .FirstOrDefaultAsync(d => d.DeviceId == request.DeviceId, ct);

        if (device is null)
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);

        // Hash the provided secret and compare to the stored hash.
        // SHA-256 is sufficient here (no stretching needed) because the secret
        // is 256-bit random — immune to dictionary/brute-force attacks.
        var computedHash = SHA256.HashData(secretBytes);

        // Constant-time comparison prevents timing side-channel attacks that
        // could leak information about the stored hash byte-by-byte.
        if (!CryptographicOperations.FixedTimeEquals(computedHash, device.DeviceSecretHash))
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);

        var (token, expiresAt) = jwtService.GenerateToken(device.DeviceId, device.UserHandle);

        return Results.Ok(new TokenResponse(token, expiresAt));
    }

    // -----------------------------------------------------------------------
    // POST /auth/refresh — Exchange valid/recently-expired JWT for a new one
    // -----------------------------------------------------------------------
    private static async Task<IResult> RefreshToken(
        HttpContext httpContext,
        AppDbContext db,
        JwtService jwtService,
        CancellationToken ct)
    {
        // Extract the Bearer token from the Authorization header.
        // We do this manually (not via [Authorize]) because the token may be
        // expired — the middleware would reject it, but we want to allow
        // recently-expired tokens for refresh within the grace period.
        var authHeader = httpContext.Request.Headers.Authorization.ToString();
        if (string.IsNullOrEmpty(authHeader) || !authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return Results.Json(new { error = "Bearer token required." }, statusCode: 401);

        var token = authHeader["Bearer ".Length..].Trim();

        // Validate with the relaxed lifetime policy (allows recently expired tokens).
        var principal = jwtService.ValidateTokenForRefresh(token);
        if (principal is null)
            return Results.Json(new { error = "Invalid or expired token." }, statusCode: 401);

        // Extract the deviceId from the validated token claims.
        var subClaim = principal.FindFirst(ClaimTypes.NameIdentifier)?.Value
                    ?? principal.FindFirst("sub")?.Value;

        if (!Guid.TryParse(subClaim, out var deviceId))
            return Results.Json(new { error = "Invalid token claims." }, statusCode: 401);

        // Verify the device still exists — it could have been deleted since
        // the original token was issued.
        var device = await db.Devices
            .FirstOrDefaultAsync(d => d.DeviceId == deviceId, ct);

        if (device is null)
            return Results.Json(new { error = "Device no longer exists." }, statusCode: 401);

        var (newToken, expiresAt) = jwtService.GenerateToken(device.DeviceId, device.UserHandle);

        return Results.Ok(new TokenResponse(newToken, expiresAt));
    }
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record TokenRequest(Guid DeviceId, string DeviceSecret);
public record TokenResponse(string Token, DateTimeOffset ExpiresAt);
