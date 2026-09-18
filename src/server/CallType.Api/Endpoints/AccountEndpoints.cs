// ---------------------------------------------------------------------------
// AccountEndpoints.cs — Account registration, login, and device linking
// ---------------------------------------------------------------------------
// Accounts are optional — a device can operate fully anonymously. Registering
// an account (email + auth key) enables cloud backups and multi-device sync.
//
// Authentication uses Argon2id with a random 16-byte salt. The server never
// stores the raw auth key — only salt || hash. FixedTimeEquals is used for
// hash comparison to prevent timing side-channel attacks.
//
// The auth key is NOT a password — it is a high-entropy key derived client-side
// from the user's passphrase using a KDF. This means the server does not need
// to worry about weak password entropy; Argon2id here protects against offline
// brute-force if the DB leaks.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using System.Security.Claims;
using Konscious.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Endpoints;

public static class AccountEndpoints
{
    // Argon2id parameters — tuned for a server environment. Lower than the
    // OWASP "first choice" recommendation (47 MiB / 1 iteration) to avoid
    // making the login endpoint a CPU/memory exhaustion vector. The auth key
    // is already high-entropy (client-side KDF output), so moderate params
    // are sufficient to deter offline attacks on a leaked DB.
    private const int Argon2SaltBytes = 16;
    private const int Argon2HashBytes = 32;
    private const int Argon2DegreeOfParallelism = 4;
    private const int Argon2MemorySize = 65536; // 64 MiB
    private const int Argon2Iterations = 3;

    /// <summary>
    /// Registers all account-related routes on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapAccountEndpoints(this WebApplication app)
    {
        // Account registration and login are public — these are part of the
        // account auth flow that happens before the device has a JWT.
        // Login uses the stricter "auth" limiter to slow down brute-force.
        app.MapPost("/accounts", RegisterAccount).AllowAnonymous().RequireRateLimiting("api");
        app.MapPost("/accounts/login", Login).AllowAnonymous().RequireRateLimiting("auth");
        // Device linking and listing require an authenticated device.
        app.MapPost("/accounts/{accountId:guid}/devices/{deviceId:guid}", LinkDevice).RequireAuthorization().RequireRateLimiting("auth");
        app.MapGet("/accounts/{accountId:guid}/devices", ListLinkedDevices).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /accounts — Register a new account
    // -----------------------------------------------------------------------
    private static async Task<IResult> RegisterAccount(
        RegisterAccountRequest request,
        AppDbContext db,
        CancellationToken ct)
    {
        // --- Validation ---------------------------------------------------
        if (string.IsNullOrWhiteSpace(request.Email) ||
            string.IsNullOrWhiteSpace(request.AuthKey))
        {
            return Results.BadRequest(new { error = "Email and AuthKey are required." });
        }

        byte[] authKeyBytes;
        try
        {
            authKeyBytes = Convert.FromBase64String(request.AuthKey);
        }
        catch (FormatException)
        {
            return Results.BadRequest(new { error = "AuthKey must be valid base64." });
        }

        if (authKeyBytes.Length == 0)
            return Results.BadRequest(new { error = "AuthKey must not be empty." });

        // Basic email format validation — catches obvious typos (missing @, etc.)
        // before we hit the database. Not a full RFC 5322 check, but good enough
        // to reject clearly invalid input early.
        try { _ = new System.Net.Mail.MailAddress(request.Email); }
        catch (FormatException) { return Results.BadRequest(new { error = "Invalid email format." }); }

        // --- Email uniqueness check (advisory — the unique index is the real guard) ---
        var emailNormalized = request.Email.Trim().ToLowerInvariant();
        var exists = await db.Accounts.AnyAsync(a => a.Email == emailNormalized, ct);
        if (exists)
            return Results.Conflict(new { error = "An account with this email already exists." });

        // --- Hash the auth key with Argon2id ---
        var authKeyHash = await HashAuthKeyAsync(authKeyBytes);

        var account = new Account
        {
            AccountId = Guid.NewGuid(),
            Email = emailNormalized,
            AuthKeyHash = authKeyHash,
            CreatedAt = DateTimeOffset.UtcNow
        };

        db.Accounts.Add(account);
        await db.SaveChangesAsync(ct);

        return Results.Created(
            $"/accounts/{account.AccountId}",
            new RegisterAccountResponse(account.AccountId));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/login — Authenticate with email + auth key
    // -----------------------------------------------------------------------
    private static async Task<IResult> Login(
        LoginRequest request,
        AppDbContext db,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Email) ||
            string.IsNullOrWhiteSpace(request.AuthKey))
        {
            return Results.BadRequest(new { error = "Email and AuthKey are required." });
        }

        byte[] authKeyBytes;
        try
        {
            authKeyBytes = Convert.FromBase64String(request.AuthKey);
        }
        catch (FormatException)
        {
            // Intentionally vague error to avoid leaking whether the email exists.
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);
        }

        var emailNormalized = request.Email.Trim().ToLowerInvariant();
        var account = await db.Accounts
            .FirstOrDefaultAsync(a => a.Email == emailNormalized, ct);

        if (account is null)
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);

        // Extract the salt (first 16 bytes) from the stored hash blob and
        // re-hash the provided auth key with the same salt for comparison.
        var isValid = await VerifyAuthKeyAsync(authKeyBytes, account.AuthKeyHash);

        if (!isValid)
            return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);

        return Results.Ok(new LoginResponse(account.AccountId));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/devices/{deviceId} — Link device to account
    // -----------------------------------------------------------------------
    private static async Task<IResult> LinkDevice(
        Guid accountId,
        Guid deviceId,
        LinkAccountDeviceRequest request,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        if (CallerDeviceId(user) != deviceId) return Results.Forbid();
        var account = await db.Accounts.AsNoTracking().SingleOrDefaultAsync(a => a.AccountId == accountId, ct);
        if (account is null) return Results.NotFound(new { error = "Account not found." });
        byte[] key;
        try { key = Convert.FromBase64String(request.AuthKey ?? ""); }
        catch (FormatException) { return Results.Forbid(); }
        if (key.Length == 0 || !await VerifyAuthKeyAsync(key, account.AuthKeyHash))
            return Results.Forbid();
        var deviceExists = await db.Devices.AnyAsync(d => d.DeviceId == deviceId, ct);
        if (!deviceExists)
            return Results.NotFound(new { error = "Device not found." });

        var alreadyLinked = await db.AccountDevices
            .AnyAsync(ad => ad.AccountId == accountId && ad.DeviceId == deviceId, ct);
        if (alreadyLinked)
            return Results.Ok(new { message = "Device is already linked to this account." });

        db.AccountDevices.Add(new AccountDevice
        {
            AccountId = accountId,
            DeviceId = deviceId,
            LinkedAt = DateTimeOffset.UtcNow
        });

        await db.SaveChangesAsync(ct);
        return Results.Ok(new { message = "Device linked successfully." });
    }

    // -----------------------------------------------------------------------
    // GET /accounts/{accountId}/devices — List linked devices
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListLinkedDevices(
        Guid accountId,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        if (!await IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();
        var devices = await db.AccountDevices
            .Where(ad => ad.AccountId == accountId)
            .Select(ad => new LinkedDeviceDto(ad.DeviceId, ad.LinkedAt))
            .ToListAsync(ct);

        return Results.Ok(devices);
    }

    // -----------------------------------------------------------------------
    internal static Guid? CallerDeviceId(ClaimsPrincipal user) =>
        Guid.TryParse(user.FindFirst(ClaimTypes.NameIdentifier)?.Value ?? user.FindFirst("sub")?.Value,
            out var id) ? id : null;

    internal static Task<bool> IsLinkedAsync(ClaimsPrincipal user, Guid accountId, AppDbContext db, CancellationToken ct)
    {
        var deviceId = CallerDeviceId(user);
        return db.AccountDevices.AnyAsync(link => link.AccountId == accountId && link.DeviceId == deviceId, ct);
    }
    // Argon2id hashing helpers
    // -----------------------------------------------------------------------

    /// <summary>
    /// Hashes the auth key with Argon2id and a random salt. Returns the
    /// concatenation salt || hash so the salt is stored alongside the hash
    /// in a single byte[] column — no extra DB column needed.
    /// </summary>
    private static async Task<byte[]> HashAuthKeyAsync(byte[] authKey)
    {
        var salt = RandomNumberGenerator.GetBytes(Argon2SaltBytes);

        using var argon2 = new Argon2id(authKey);
        argon2.Salt = salt;
        argon2.DegreeOfParallelism = Argon2DegreeOfParallelism;
        argon2.MemorySize = Argon2MemorySize;
        argon2.Iterations = Argon2Iterations;

        var hash = await argon2.GetBytesAsync(Argon2HashBytes);

        // salt || hash — salt is always Argon2SaltBytes long, so extraction
        // during verification is trivial (first N bytes = salt, rest = hash).
        var result = new byte[Argon2SaltBytes + Argon2HashBytes];
        salt.CopyTo(result, 0);
        hash.CopyTo(result, Argon2SaltBytes);
        return result;
    }

    /// <summary>
    /// Verifies an auth key against a stored salt || hash blob.
    /// Uses CryptographicOperations.FixedTimeEquals to prevent timing attacks.
    /// Internal (not private) so PrivacyEndpoints (DELETE /accounts/{id}) can
    /// reuse the exact same irreversible-deletion proof-of-possession check
    /// that LinkDevice uses, instead of duplicating the Argon2id parameters.
    /// </summary>
    internal static async Task<bool> VerifyAuthKeyAsync(byte[] authKey, byte[] storedHash)
    {
        if (storedHash.Length != Argon2SaltBytes + Argon2HashBytes)
            return false;

        // Extract salt (first 16 bytes) and expected hash (remaining 32 bytes).
        var salt = storedHash.AsSpan(0, Argon2SaltBytes).ToArray();
        var expectedHash = storedHash.AsSpan(Argon2SaltBytes).ToArray();

        using var argon2 = new Argon2id(authKey);
        argon2.Salt = salt;
        argon2.DegreeOfParallelism = Argon2DegreeOfParallelism;
        argon2.MemorySize = Argon2MemorySize;
        argon2.Iterations = Argon2Iterations;

        var computedHash = await argon2.GetBytesAsync(Argon2HashBytes);

        return CryptographicOperations.FixedTimeEquals(computedHash, expectedHash);
    }
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record RegisterAccountRequest(string Email, string AuthKey);
public record RegisterAccountResponse(Guid AccountId);
public record LoginRequest(string Email, string AuthKey);
public record LoginResponse(Guid AccountId);
public record LinkedDeviceDto(Guid DeviceId, DateTimeOffset LinkedAt);

public record LinkAccountDeviceRequest(string? AuthKey);
