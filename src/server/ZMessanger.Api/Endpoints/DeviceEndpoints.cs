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

using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Endpoints;

public static class DeviceEndpoints
{
    // Characters used for handle generation. Excludes ambiguous characters
    // (0/O, 1/I/L) to reduce transcription errors when users type handles.
    private const string HandleChars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

    /// <summary>
    /// Registers all device-related routes on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapDeviceEndpoints(this WebApplication app)
    {
        app.MapPost("/devices", RegisterDevice);
        app.MapGet("/devices/{id:guid}/key-bundle", GetKeyBundle);
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

        // --- Handle generation --------------------------------------------
        var userHandle = await GenerateUniqueHandle(db, ct);

        // --- Build the Device entity --------------------------------------
        var now = DateTimeOffset.UtcNow;
        var device = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = userHandle,
            IdentityKey = identityKeyBytes,
            SignedPreKey = signedPreKeyBytes,
            CreatedAt = now,
            LastSeenAt = now
        };

        // --- Store one-time pre-keys if provided --------------------------
        if (request.OneTimePreKeys is { Count: > 0 })
        {
            foreach (var otk in request.OneTimePreKeys)
            {
                device.OneTimePreKeys.Add(new OneTimePreKey
                {
                    DeviceId = device.DeviceId,
                    KeyId = otk.KeyId,
                    PublicKey = Convert.FromBase64String(otk.PublicKey)
                });
            }
        }

        db.Devices.Add(device);
        await db.SaveChangesAsync(ct);

        return Results.Created(
            $"/devices/{device.DeviceId}",
            new RegisterDeviceResponse(device.DeviceId, device.UserHandle));
    }

    // -----------------------------------------------------------------------
    // GET /devices/{id}/key-bundle — Fetch key bundle for X3DH handshake
    // -----------------------------------------------------------------------
    private static async Task<IResult> GetKeyBundle(
        Guid id,
        AppDbContext db,
        CancellationToken ct)
    {
        var device = await db.Devices
            .Include(d => d.OneTimePreKeys)
            .FirstOrDefaultAsync(d => d.DeviceId == id, ct);

        if (device is null)
            return Results.NotFound(new { error = "Device not found." });

        // Consume one OTK if available. The X3DH protocol benefits from a
        // one-time key but can fall back to the signed pre-key alone.
        // NOTE: Under high concurrency two requests could read the same OTK
        // before either deletes it. The protocol tolerates this (the session
        // just falls back to the signed pre-key). A future optimisation could
        // use a raw SQL DELETE ... RETURNING to make consumption atomic.
        OneTimePreKeyDto? oneTimePreKeyDto = null;

        var otk = device.OneTimePreKeys.FirstOrDefault();
        if (otk is not null)
        {
            oneTimePreKeyDto = new OneTimePreKeyDto(otk.KeyId, Convert.ToBase64String(otk.PublicKey));
            db.OneTimePreKeys.Remove(otk);
            await db.SaveChangesAsync(ct);
        }

        return Results.Ok(new KeyBundleResponse(
            device.DeviceId,
            Convert.ToBase64String(device.IdentityKey),
            Convert.ToBase64String(device.SignedPreKey),
            oneTimePreKeyDto));
    }

    // -----------------------------------------------------------------------
    // Handle generation
    // -----------------------------------------------------------------------

    /// <summary>
    /// Generates a handle in format ZM-XXXX-XXXX using cryptographically
    /// random characters, retrying on the (very unlikely) collision.
    /// </summary>
    /// <remarks>
    /// With 30 possible chars and 8 random positions, there are ~6.5×10^11
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
            var handle = GenerateHandle();
            var exists = await db.Devices.AnyAsync(d => d.UserHandle == handle, ct);
            if (!exists)
                return handle;
        }

        // If we get here something is seriously wrong.
        throw new InvalidOperationException(
            "Failed to generate a unique user handle after maximum retry attempts.");
    }

    private static string GenerateHandle()
    {
        // Use stack allocation for the 8-char random portion to avoid
        // heap pressure on a potentially hot registration path.
        Span<char> part1 = stackalloc char[4];
        Span<char> part2 = stackalloc char[4];

        FillRandom(part1);
        FillRandom(part2);

        return $"ZM-{part1}-{part2}";
    }

    private static void FillRandom(Span<char> buffer)
    {
        // RandomNumberGenerator is cryptographically secure and thread-safe,
        // ensuring handles cannot be predicted or enumerated.
        Span<byte> randomBytes = stackalloc byte[buffer.Length];
        RandomNumberGenerator.Fill(randomBytes);

        for (var i = 0; i < buffer.Length; i++)
        {
            // Modulo bias is negligible here: 256 % 30 = 16, giving at most
            // ~6% over-representation for some characters. This is acceptable
            // for an identifier, not a cryptographic key.
            buffer[i] = HandleChars[randomBytes[i] % HandleChars.Length];
        }
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
    List<OneTimePreKeyInput>? OneTimePreKeys);

public record OneTimePreKeyInput(int KeyId, string PublicKey);

public record RegisterDeviceResponse(Guid DeviceId, string UserHandle);

public record KeyBundleResponse(
    Guid DeviceId,
    string IdentityKey,
    string SignedPreKey,
    OneTimePreKeyDto? OneTimePreKey);

public record OneTimePreKeyDto(int KeyId, string PublicKey);
