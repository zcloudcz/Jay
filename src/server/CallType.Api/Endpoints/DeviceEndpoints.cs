// ---------------------------------------------------------------------------
// DeviceEndpoints.cs — Device registration and key bundle API
// ---------------------------------------------------------------------------
// These endpoints handle the first step of the X3DH key agreement protocol:
// 1. POST /devices  — A new device joins the network by uploading its key
//    material and receiving a unique human-readable handle.
// 2. GET  /devices/{id}/key-bundle — Another device fetches the key bundle
//    needed to initiate an encrypted session (X3DH handshake).
//
// The server never sees plaintext messages; it only brokers public keys.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class DeviceEndpoints
{
    /// <summary>
    /// Registers all device-related routes on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapDeviceEndpoints(this WebApplication app)
    {
        // Device registration is public — new devices don't have credentials yet.
        app.MapPost("/devices", RegisterDevice).AllowAnonymous().RequireRateLimiting("api");
        // Key bundle fetch requires auth — only registered devices should be able
        // to look up other devices' keys to prevent key-bundle enumeration.
        app.MapGet("/devices/{id:guid}/key-bundle", GetKeyBundle).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/devices/by-handle/{handle}", FindDeviceByHandle).RequireAuthorization().RequireRateLimiting("api");
        // Push token registration requires auth AND that {id} is the caller's
        // own device (JWT sub) — see RequireSelf. Uses PUT because the token is
        // idempotent (setting the same token twice is a no-op).
        app.MapPut("/devices/{id:guid}/push-token", UpdatePushToken).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/devices/{id:guid}/push-token", DeletePushToken).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /devices — Register a new device
    // -----------------------------------------------------------------------
    private static async Task<IResult> RegisterDevice(
        RegisterDeviceRequest request,
        AppDbContext db,
        CancellationToken ct)
    {
        // --- Validation ---------------------------------------------------
        // Both keys are mandatory for X3DH. Without them no peer can
        // establish an encrypted session with this device.
        if (string.IsNullOrWhiteSpace(request.IdentityKey) ||
            string.IsNullOrWhiteSpace(request.SignedPreKey))
        {
            return Results.BadRequest(new { error = "IdentityKey and SignedPreKey are required." });
        }

        byte[] identityKeyBytes;
        byte[] signedPreKeyBytes;

        try
        {
            identityKeyBytes = Convert.FromBase64String(request.IdentityKey);
            signedPreKeyBytes = Convert.FromBase64String(request.SignedPreKey);
        }
        catch (FormatException)
        {
            return Results.BadRequest(new { error = "IdentityKey and SignedPreKey must be valid base64." });
        }

        // Zero-length keys are technically valid base64 ("") but useless
        // for cryptographic purposes — reject them explicitly.
        if (identityKeyBytes.Length == 0 || signedPreKeyBytes.Length == 0)
        {
            return Results.BadRequest(new { error = "IdentityKey and SignedPreKey must not be empty." });
        }

        byte[]? signingKey = null;
        byte[]? signature = null;
        if (request.SigningKey is not null || request.Signature is not null)
        {
            try
            {
                signingKey = Convert.FromBase64String(request.SigningKey ?? "");
                signature = Convert.FromBase64String(request.Signature ?? "");
            }
            catch (FormatException)
            {
                return Results.BadRequest(new { error = "Signing key and signature must be base64." });
            }
            if (signingKey.Length != 32 || signature.Length != 64 || identityKeyBytes.Length != 32 || signedPreKeyBytes.Length != 32)
                return Results.BadRequest(new { error = "Invalid signed identity bundle lengths." });
        }

        // --- Handle generation --------------------------------------------
        var userHandle = await GenerateUniqueHandle(db, ct);

        // --- Generate device secret -----------------------------------------
        // The device secret is a 32-byte random value returned to the client
        // exactly once (in this response). Only the SHA-256 hash is stored.
        // This is the credential the device uses to obtain JWTs via /auth/token.
        var deviceSecret = RandomNumberGenerator.GetBytes(32);
        var deviceSecretHash = System.Security.Cryptography.SHA256.HashData(deviceSecret);

        // --- Build the Device entity --------------------------------------
        var now = DateTimeOffset.UtcNow;
        var device = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = userHandle,
            IdentityKey = identityKeyBytes,
            SignedPreKey = signedPreKeyBytes,
            SigningKey = signingKey,
            Signature = signature,
            DeviceSecretHash = deviceSecretHash,
            // Self-declared at registration and never updated afterwards — no
            // endpoint writes this column, so a human contact cannot silently
            // turn into a bot (or hide that it is one) later.
            IsBot = request.IsBot,
            CreatedAt = now,
            LastSeenAt = now
        };

        // --- Store one-time pre-keys if provided --------------------------
        if (request.OneTimePreKeys is { Count: > 0 })
        {
            foreach (var otk in request.OneTimePreKeys)
            {
                if (string.IsNullOrWhiteSpace(otk.PublicKey))
                    return Results.BadRequest(new { error = "OneTimePreKey PublicKey must not be null or empty." });

                byte[] otkBytes;
                try
                {
                    otkBytes = Convert.FromBase64String(otk.PublicKey);
                }
                catch (FormatException)
                {
                    return Results.BadRequest(new { error = $"OneTimePreKey with KeyId {otk.KeyId} has invalid base64." });
                }

                if (otkBytes.Length == 0)
                    return Results.BadRequest(new { error = $"OneTimePreKey with KeyId {otk.KeyId} must not be empty." });

                device.OneTimePreKeys.Add(new OneTimePreKey
                {
                    DeviceId = device.DeviceId,
                    KeyId = otk.KeyId,
                    PublicKey = otkBytes
                });
            }
        }

        db.Devices.Add(device);

        // --- Persist with collision retry (Fix 3: TOCTOU) ----------------
        // The pre-check in GenerateUniqueHandle reduces collisions but a
        // concurrent registration could still insert the same handle between
        // the AnyAsync check and our SaveChanges. Catch the unique-constraint
        // violation and retry with a fresh handle.
        const int maxSaveAttempts = 3;
        for (var saveAttempt = 0; saveAttempt < maxSaveAttempts; saveAttempt++)
        {
            try
            {
                await db.SaveChangesAsync(ct);
                break; // success
            }
            catch (DbUpdateException ex)
                when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
            {
                if (saveAttempt == maxSaveAttempts - 1)
                    throw; // exhausted retries — let it bubble up

                // Detach the failed tracker state and regenerate the handle.
                db.ChangeTracker.Clear();

                device.UserHandle = await GenerateUniqueHandle(db, ct);

                db.Devices.Add(device);
            }
        }

        // Return the raw secret as base64. This is the ONLY time the client
        // will ever see the secret — it is not stored on the server.
        return Results.Created(
            $"/devices/{device.DeviceId}",
            new RegisterDeviceResponse(device.DeviceId, device.UserHandle, Convert.ToBase64String(deviceSecret)));
    }

    // -----------------------------------------------------------------------
    // GET /devices/{id}/key-bundle — Fetch key bundle for X3DH handshake
    // -----------------------------------------------------------------------
    private static async Task<IResult> GetKeyBundle(
        Guid id,
        AppDbContext db,
        CancellationToken ct)
    {
        // Load device WITHOUT OTKs — the atomic SQL below handles OTK consumption.
        var device = await db.Devices
            .FirstOrDefaultAsync(d => d.DeviceId == id, ct);

        if (device is null)
            return Results.NotFound(new { error = "Device not found." });

        // Atomically consume one OTK using DELETE ... RETURNING so two
        // concurrent requests can never consume the same key. FOR UPDATE
        // SKIP LOCKED ensures waiters grab the next available key instead
        // of blocking or duplicating.
        OneTimePreKeyDto? oneTimePreKeyDto = null;

        var consumed = await db.Database.SqlQueryRaw<OtkResult>(
            """
            DELETE FROM "OneTimePreKeys"
            WHERE "Id" = (
                SELECT "Id" FROM "OneTimePreKeys"
                WHERE "DeviceId" = @deviceId
                ORDER BY "Id"
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            RETURNING "Id", "KeyId", "PublicKey"
            """,
            new NpgsqlParameter("@deviceId", id))
            .ToListAsync(ct);

        if (consumed.Count > 0)
        {
            var otk = consumed[0];
            oneTimePreKeyDto = new OneTimePreKeyDto(otk.KeyId, Convert.ToBase64String(otk.PublicKey));
        }

        return Results.Ok(new KeyBundleResponse(
            device.DeviceId,
            Convert.ToBase64String(device.IdentityKey),
            Convert.ToBase64String(device.SignedPreKey),
            oneTimePreKeyDto,
            device.SigningKey is null ? null : Convert.ToBase64String(device.SigningKey),
            device.Signature is null ? null : Convert.ToBase64String(device.Signature),
            device.IsBot));
    }

    private static async Task<IResult> FindDeviceByHandle(string handle, AppDbContext db, CancellationToken ct)
    {
        var normalized = handle.Trim().ToUpperInvariant();
        var device = await db.Devices.Where(d => d.UserHandle == normalized)
            // IsBot is included so the client can show the BOT badge BEFORE the
            // user adds the contact (lookup is the first thing the add flow calls).
            .Select(d => new { d.DeviceId, d.UserHandle, d.IsBot }).SingleOrDefaultAsync(ct);
        return device is null ? Results.NotFound() : Results.Ok(device);
    }

    // -----------------------------------------------------------------------
    // PUT /devices/{id}/push-token — Register or update push notification token
    // -----------------------------------------------------------------------
    // "apns-voip" is a PushKit token: it goes to its own slot (VoipPushToken)
    // and never into PushPlatform, whose value set stays fcm|apns.
    private static readonly string[] PushPlatforms = ["fcm", "apns", "apns-voip"];
    private static readonly string[] ApnsEnvironments = ["production", "sandbox"];
    private const int MaxPushTokenLength = 512;
    private const int PushKeyLength = 32;

    /// <summary>
    /// 403 device_mismatch unless {id} is the calling device (JWT sub). Before
    /// X0 any authenticated device could overwrite ANY device's push token and
    /// redirect its wake-ups (IDOR, security plan R1). Same identity source as
    /// every other device-scoped endpoint (AccountEndpoints.CallerDeviceId);
    /// the full "path id vs. JWT" audit of all endpoints stays with stream S (S1).
    /// </summary>
    private static IResult? RequireSelf(ClaimsPrincipal user, Guid id) =>
        AccountEndpoints.CallerDeviceId(user) == id
            ? null
            : Results.Json(new { error = "Path device id does not match the authenticated device.", code = "device_mismatch" },
                statusCode: StatusCodes.Status403Forbidden);

    private static IResult PushTokenError(string code, string error) =>
        Results.BadRequest(new { error, code });

    private static async Task<IResult> UpdatePushToken(
        Guid id,
        UpdatePushTokenRequest request,
        ClaimsPrincipal user,
        AppDbContext db,
        TimeProvider clock,
        CancellationToken ct)
    {
        if (RequireSelf(user, id) is { } forbidden) return forbidden;

        // Validate platform — only known push platforms are accepted.
        // This prevents storing tokens for unsupported platforms that would
        // silently fail at push time with no useful diagnostic.
        if (!PushPlatforms.Contains(request.Platform))
            return PushTokenError("invalid_platform", "Platform must be 'fcm', 'apns' or 'apns-voip'.");

        // Upper bound: FCM tokens are ~160-250 chars, APNs 64 hex; 512 leaves
        // room without letting a client park arbitrary data in the column.
        if (string.IsNullOrWhiteSpace(request.Token) || request.Token.Length > MaxPushTokenLength)
            return PushTokenError("invalid_token", $"Token must be 1-{MaxPushTokenLength} characters.");

        // VoipPushToken is varchar(200) — reject instead of letting the DB throw a 500.
        if (request.Platform == "apns-voip" && request.Token.Length > 200)
            return PushTokenError("invalid_token", "A PushKit token must be at most 200 characters.");

        // The environment only means something for APNs (gateway choice); it is
        // a hint that stream N corrects from APNs responses.
        if (request.Environment is not null && !ApnsEnvironments.Contains(request.Environment))
            return PushTokenError("invalid_environment", "Environment must be 'production' or 'sandbox'.");

        byte[]? pushKey = null;
        if (request.PushKey is not null)
        {
            try { pushKey = Convert.FromBase64String(request.PushKey); }
            catch (FormatException) { return PushTokenError("invalid_push_key", "PushKey must be base64 of exactly 32 bytes."); }
            if (pushKey.Length != PushKeyLength)
                return PushTokenError("invalid_push_key", "PushKey must be base64 of exactly 32 bytes.");
        }

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == id, ct);
        if (device is null)
            return Results.NotFound(new { error = "Device not found." });

        if (request.Platform == "apns-voip")
        {
            // Separate slot: an iPhone also has an alert token in PushToken for
            // messages, which a PushKit registration must not overwrite.
            device.VoipPushToken = request.Token;
            device.VoipPushEnvironment = request.Environment;
        }
        else
        {
            // Overwrite previous token — a device has at most one active alert
            // push token. When the client refreshes its FCM token, it calls this
            // endpoint with the new token, replacing the stale one.
            device.PushToken = request.Token;
            device.PushPlatform = request.Platform;
        }

        // Stored regardless of platform: one key per device encrypts the hint
        // for every channel it is woken through. Omitted = keep the old key.
        if (pushKey is not null)
            device.PushKey = pushKey;
        device.PushTokenUpdatedAt = clock.GetUtcNow();

        await db.SaveChangesAsync(ct);

        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // DELETE /devices/{id}/push-token?platform=fcm|apns|apns-voip
    // -----------------------------------------------------------------------
    // Logout / notifications switched off: the client drops one slot. Always
    // 204 for an existing own device, even when the slot is already empty
    // (idempotent). fcm|apns also drops PushKey — the alert channel is the one
    // that carries message hints; apns-voip leaves it for the alert channel.
    private static async Task<IResult> DeletePushToken(
        Guid id,
        string? platform,
        ClaimsPrincipal user,
        AppDbContext db,
        TimeProvider clock,
        CancellationToken ct)
    {
        if (RequireSelf(user, id) is { } forbidden) return forbidden;

        if (platform is null || !PushPlatforms.Contains(platform))
            return PushTokenError("invalid_platform", "Query parameter platform must be 'fcm', 'apns' or 'apns-voip'.");

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == id, ct);
        if (device is null)
            return Results.NotFound(new { error = "Device not found." });

        if (platform == "apns-voip")
        {
            device.VoipPushToken = null;
            device.VoipPushEnvironment = null;
        }
        else if (device.PushPlatform is null || device.PushPlatform == platform)
        {
            // Only clear the alert slot if it holds THIS platform's token: a
            // stale "apns" delete must not wipe a freshly registered FCM token.
            device.PushToken = null;
            device.PushPlatform = null;
            device.PushKey = null;
        }
        device.PushTokenUpdatedAt = clock.GetUtcNow();

        await db.SaveChangesAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// Result type for the DELETE ... RETURNING SQL query on OneTimePreKeys.
    /// Must be a class (not a record) with a parameterless constructor for
    /// EF Core's SqlQueryRaw materialization.
    /// </summary>
    private class OtkResult
    {
        public long Id { get; set; }
        public int KeyId { get; set; }
        public byte[] PublicKey { get; set; } = [];
    }

    // -----------------------------------------------------------------------
    // Handle generation
    // -----------------------------------------------------------------------

    /// <summary>
    /// Generates a handle in format CT-XXXX-XXXX using cryptographically
    /// random characters, retrying on the (very unlikely) collision.
    /// </summary>
    /// <remarks>
    /// With 30 possible chars and 8 random positions, there are ~6.5x10^11
    /// combinations — more than enough for the expected device population.
    /// The DB unique index is the final safety net against collisions.
    /// </remarks>
    private static async Task<string> GenerateUniqueHandle(AppDbContext db, CancellationToken ct)
    {
        // Cap retries to avoid infinite loops on pathological edge cases
        // (e.g. handle space exhaustion, which will never happen in practice).
        const int maxAttempts = 10;

        for (var attempt = 0; attempt < maxAttempts; attempt++)
        {
            var handle = HandleGenerator.Generate(HandleGenerator.DevicePrefix);
            var exists = await db.Devices.AnyAsync(d => d.UserHandle == handle, ct);
            if (!exists)
                return handle;
        }

        // If we get here something is seriously wrong.
        throw new InvalidOperationException(
            "Failed to generate a unique user handle after maximum retry attempts.");
    }
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------
// Records give us immutable, value-semantic DTOs with minimal boilerplate.
// System.Text.Json handles serialization via the constructor parameters.
// ---------------------------------------------------------------------------

public record RegisterDeviceRequest(
    string IdentityKey,
    string SignedPreKey,
    List<OneTimePreKeyInput>? OneTimePreKeys,
    string? SigningKey = null,
    string? Signature = null,
    bool IsBot = false);

public record OneTimePreKeyInput(int KeyId, string PublicKey);

public record RegisterDeviceResponse(Guid DeviceId, string UserHandle, string DeviceSecret);

public record KeyBundleResponse(
    Guid DeviceId,
    string IdentityKey,
    string SignedPreKey,
    OneTimePreKeyDto? OneTimePreKey,
    string? SigningKey = null,
    string? Signature = null,
    bool IsBot = false);

public record OneTimePreKeyDto(int KeyId, string PublicKey);

/// <param name="Token">Provider token (FCM registration token, APNs device token, PushKit token).</param>
/// <param name="Platform">"fcm" | "apns" | "apns-voip".</param>
/// <param name="Environment">Optional APNs gateway hint: "production" | "sandbox".</param>
/// <param name="PushKey">Optional base64 of exactly 32 bytes — key for the encrypted push hint.</param>
public record UpdatePushTokenRequest(string Token, string Platform, string? Environment = null, string? PushKey = null);
