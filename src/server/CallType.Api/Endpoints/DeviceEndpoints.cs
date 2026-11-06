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
using System.Text.Json;
using System.Text.RegularExpressions;
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
        // Push token registration: only the device itself (Caller == {id}).
        // Uses PUT because the token is idempotent (setting the same token
        // twice is a no-op); DELETE turns pushes off (logout, setting off).
        app.MapPut("/devices/{id:guid}/push-token", UpdatePushToken).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/devices/{id:guid}/push-token", DeletePushToken).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/devices/{id:guid}/voip-token", UpdateVoipToken).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/devices/{id:guid}/voip-token", DeleteVoipToken).RequireAuthorization().RequireRateLimiting("api");
        // Display name is opt-in metadata the device owner sets for itself — only
        // the authenticated caller matching {id} may change it (see Caller check
        // in UpdateProfile).
        app.MapPut("/devices/{id:guid}/profile", UpdateProfile).RequireAuthorization().RequireRateLimiting("api");
        // Bot commands: written only by the bot device itself, readable by any
        // authenticated device (the "/" menu of whoever chats with the bot).
        app.MapPut("/devices/{id:guid}/bot-commands", PutBotCommands).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/devices/{id:guid}/bot-commands", GetBotCommands).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static Guid Caller(ClaimsPrincipal user) => Guid.TryParse(
        user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub"), out var id) ? id : Guid.Empty;

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
            device.IsBot,
            device.DisplayName));
    }

    private static async Task<IResult> FindDeviceByHandle(string handle, AppDbContext db, CancellationToken ct)
    {
        var normalized = handle.Trim().ToUpperInvariant();
        var device = await db.Devices.Where(d => d.UserHandle == normalized)
            // IsBot is included so the client can show the BOT badge BEFORE the
            // user adds the contact (lookup is the first thing the add flow calls).
            .Select(d => new { d.DeviceId, d.UserHandle, d.IsBot, d.DisplayName }).SingleOrDefaultAsync(ct);
        return device is null ? Results.NotFound() : Results.Ok(device);
    }

    // -----------------------------------------------------------------------
    // PUT /devices/{id}/profile — Set the device's own display name
    // -----------------------------------------------------------------------
    private static async Task<IResult> UpdateProfile(
        Guid id,
        UpdateProfileRequest request,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        // A display name is shown to other people, so only the device itself
        // may set it, never another authenticated caller.
        if (Caller(user) != id)
            return Results.Forbid();

        // Empty string clears the name (falls back to showing the handle), so
        // trim first and treat "" the same as null rather than storing blank.
        var trimmed = request.DisplayName?.Trim();
        if (trimmed is { Length: > 60 })
            return Results.BadRequest(new { error = "DisplayName must be at most 60 characters." });

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == id, ct);
        if (device is null)
            return Results.NotFound(new { error = "Device not found." });

        device.DisplayName = string.IsNullOrEmpty(trimmed) ? null : trimmed;
        await db.SaveChangesAsync(ct);

        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // PUT/GET /devices/{id}/bot-commands - Bot command menu
    // -----------------------------------------------------------------------
    internal const int MaxBotCommands = 50;
    internal const int MaxBotCommandDescription = 100;

    // Same alphabet as Telegram's setMyCommands minus upper case: clients
    // insert "/cmd@HANDLE" into the composer, so the token must survive being
    // typed and matched without case folding or escaping.
    private static readonly Regex BotCommandPattern = new("^[a-z0-9_]{1,32}$", RegexOptions.CultureInvariant);

    // Stored JSON uses the exact wire names, so GET can return it verbatim
    // through the same DTO and the column stays readable in psql.
    private static readonly JsonSerializerOptions BotCommandsJson = new(JsonSerializerDefaults.Web);

    private static async Task<IResult> PutBotCommands(
        Guid id,
        BotCommandsRequest request,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        // Commands are shown to everybody who chats with the bot, so only the
        // bot device itself may publish them (like UpdateProfile).
        if (Caller(user) != id)
            return Results.Forbid();

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == id, ct);
        if (device is null)
            return Results.NotFound(new { error = "Device not found." });
        // A human device with a command menu would look like a bot to other
        // clients; IsBot is immutable, so this cannot be bypassed later.
        if (!device.IsBot)
            return Results.Problem(title: "Not a bot", detail: "Only a bot device can publish commands.",
                statusCode: StatusCodes.Status403Forbidden,
                extensions: new Dictionary<string, object?> { ["error"] = "not_a_bot" });

        var (commands, problem) = ValidateBotCommands(request.Commands);
        if (problem is not null)
            return Results.Problem(title: "Invalid bot commands", detail: problem,
                statusCode: StatusCodes.Status400BadRequest,
                extensions: new Dictionary<string, object?> { ["error"] = "invalid_bot_commands" });

        // Empty list clears: store null so "never published" and "cleared"
        // look the same to readers and the column carries no empty JSON.
        device.BotCommandsJson = commands.Count == 0 ? null : JsonSerializer.Serialize(commands, BotCommandsJson);
        await db.SaveChangesAsync(ct);
        return Results.Ok(new BotCommandsResponse(commands));
    }

    private static async Task<IResult> GetBotCommands(Guid id, AppDbContext db, CancellationToken ct)
    {
        var device = await db.Devices.AsNoTracking().Where(d => d.DeviceId == id)
            .Select(d => new { d.IsBot, d.BotCommandsJson }).SingleOrDefaultAsync(ct);
        if (device is null)
            return Results.NotFound(new { error = "Device not found." });
        // A non-bot is answered with an empty list instead of an error: the
        // client asks for every chat partner it suspects is a bot and only
        // needs "no menu", not a reason.
        var commands = device.IsBot && device.BotCommandsJson is not null
            ? JsonSerializer.Deserialize<List<BotCommandDto>>(device.BotCommandsJson, BotCommandsJson) ?? []
            : [];
        return Results.Ok(new BotCommandsResponse(commands));
    }

    /// <summary>
    /// Returns the normalized list (descriptions trimmed) or a human-readable
    /// reason. The whole request is rejected on the first bad entry instead
    /// of silently dropping it, so a bot learns about its mistake at startup.
    /// </summary>
    private static (List<BotCommandDto> Commands, string? Problem) ValidateBotCommands(List<BotCommandDto?>? input)
    {
        if (input is null)
            return ([], "commands is required (an empty list clears).");
        if (input.Count > MaxBotCommands)
            return ([], $"At most {MaxBotCommands} commands are allowed.");

        var result = new List<BotCommandDto>(input.Count);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in input)
        {
            if (entry?.Command is null || !BotCommandPattern.IsMatch(entry.Command))
                return ([], "command must match ^[a-z0-9_]{1,32}$.");
            if (!seen.Add(entry.Command))
                return ([], $"Duplicate command '{entry.Command}'.");
            var description = entry.Description?.Trim() ?? "";
            if (description.Length is 0 or > MaxBotCommandDescription)
                return ([], $"description must be 1 to {MaxBotCommandDescription} characters after trimming.");
            result.Add(new BotCommandDto(entry.Command, description));
        }
        return (result, null);
    }

    // -----------------------------------------------------------------------
    // PUT /devices/{id}/push-token — Register or update push notification token
    // -----------------------------------------------------------------------
    private static async Task<IResult> UpdatePushToken(
        Guid id,
        UpdatePushTokenRequest request,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        // Only the device itself: another device registering ITS token here
        // would redirect this device's (generic, but timed) notifications to
        // a phone the attacker holds, a presence/activity side channel.
        if (Caller(user) != id)
            return Results.Forbid();

        // Validate per platform up front: a token that cannot work would
        // otherwise fail silently at push time with no useful diagnostic.
        var (token, tokenError) = PushRegistration.ValidateToken(request.Platform, request.Token);
        if (tokenError is not null)
            return PushProblem(tokenError, tokenError == PushRegistration.InvalidPlatform
                ? "Platform must be 'fcm', 'apns' or 'webpush'."
                : "Token is missing, too long or not valid for the platform.");
        var (locale, localeError) = PushRegistration.ValidateLocale(request.Locale);
        if (localeError is not null)
            return PushProblem(localeError, "Locale must be a BCP-47 tag of at most 16 characters.");

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == id, ct);
        if (device is null)
            return Results.NotFound(new { error = "Device not found." });

        // Overwrite previous token — a device has at most one active push token.
        // When the client refreshes its token, it calls this endpoint with the
        // new token, replacing the stale one (and possibly the platform).
        device.PushToken = token;
        device.PushPlatform = request.Platform;
        device.PushLocale = locale;
        // Call ringing (spec 2026-11-06-call-ringing 1.1): only an FCM app can
        // declare it handles data-only ring pushes. iOS rings through its own
        // VoIP token, and an old app that omits the field must stay on the
        // visible "Incoming call" push it understands.
        device.PushRingCalls = request.Platform == "fcm" && request.RingCalls == true;

        await db.SaveChangesAsync(ct);

        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // DELETE /devices/{id}/push-token: stop server pushes to this device
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeletePushToken(
        Guid id,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        if (Caller(user) != id)
            return Results.Forbid();

        // Idempotent: clearing an already empty registration is still 204,
        // so a logout that retries never sees an error.
        await db.Devices.Where(d => d.DeviceId == id)
            .ExecuteUpdateAsync(s => s
                .SetProperty(d => d.PushToken, (string?)null)
                .SetProperty(d => d.PushPlatform, (string?)null)
                .SetProperty(d => d.PushLocale, (string?)null)
                // Logout / notifications off must also stop the phone from
                // RINGING, so the ring registration goes with the alert one.
                .SetProperty(d => d.PushRingCalls, false)
                .SetProperty(d => d.VoipPushToken, (string?)null), ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // PUT /devices/{id}/voip-token: iOS PushKit token for call ringing
    // -----------------------------------------------------------------------
    // Its own route instead of a second field on push-token: iOS delivers the
    // VoIP token through PushKit at a different moment than the alert token,
    // and either may rotate on its own.
    private static async Task<IResult> UpdateVoipToken(
        Guid id,
        UpdateVoipTokenRequest request,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        // Self only, same reason as push-token: another device's token here
        // would make THIS device's calls ring a phone the attacker holds.
        if (Caller(user) != id)
            return Results.Forbid();

        // A VoIP token is an APNs device token: same hex rule, stored lowercase.
        var (token, error) = PushRegistration.ValidateToken("apns", request.Token);
        if (error is not null)
            return PushProblem(PushRegistration.InvalidToken, "Token must be 64 to 200 hex characters.");

        var updated = await db.Devices.Where(d => d.DeviceId == id)
            .ExecuteUpdateAsync(s => s.SetProperty(d => d.VoipPushToken, token), ct);
        return updated == 0 ? Results.NotFound(new { error = "Device not found." }) : Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // DELETE /devices/{id}/voip-token: stop ringing this device (idempotent)
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeleteVoipToken(
        Guid id,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        if (Caller(user) != id)
            return Results.Forbid();

        await db.Devices.Where(d => d.DeviceId == id)
            .ExecuteUpdateAsync(s => s.SetProperty(d => d.VoipPushToken, (string?)null), ct);
        return Results.NoContent();
    }

    private static IResult PushProblem(string error, string detail) =>
        Results.Problem(title: "Invalid push registration", detail: detail,
            statusCode: StatusCodes.Status400BadRequest,
            extensions: new Dictionary<string, object?> { ["error"] = error });

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
    bool IsBot = false,
    string? DisplayName = null);

public record OneTimePreKeyDto(int KeyId, string PublicKey);

// Nullable so a missing field is a 400 from the validator, not a binder failure.
/// <param name="RingCalls">
/// Android app handles data-only ring pushes (call-ringing spec 1.1). Optional
/// so old apps keep working; ignored for any platform other than "fcm".
/// </param>
public record UpdatePushTokenRequest(string? Token, string? Platform, string? Locale = null, bool? RingCalls = null);

public record UpdateVoipTokenRequest(string? Token);

public record UpdateProfileRequest(string? DisplayName);

// Entries are nullable so a JSON null inside the list is a 400
// invalid_bot_commands from our validator, not a binder failure.
public record BotCommandsRequest(List<BotCommandDto?>? Commands);

public record BotCommandDto(string Command, string Description);

public record BotCommandsResponse(List<BotCommandDto> Commands);
