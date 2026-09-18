// ---------------------------------------------------------------------------
// MfaEndpoints.cs — TOTP MFA enrollment/verification for an Account (N03a)
// ---------------------------------------------------------------------------
// MFA is mandatory in v1 for organization roles Owner/OrgAdmin/AuditorApprover
// (N03b enforces that via MfaAuthHelper.RequireStepUp in the org/emergency
// endpoints — NOT this file). This file only manages an account's MFA state
// and mints the short-lived step-up token that proves a passed check.
//
// Caller identity: every route requires the calling DEVICE to be linked to
// the {accountId} in the route (AccountEndpoints.IsLinkedAsync — same rule
// AccountEndpoints/OrganizationEndpoints use), regardless of whether that
// device itself has any organization role.
//
// Guessing resistance: the "auth" rate limiter (per-IP) plus a per-account
// failure counter (5 consecutive failures -> 15 min lock, 429 mfa_locked).
// The counter is updated with a single atomic UPDATE (ExecuteUpdateAsync) so
// concurrent guesses can't race past the limit.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class MfaEndpoints
{
    private const int SecretBytes = 20; // 160 bits — standard TOTP secret size (RFC 4226 §4 recommends >= 128 bits)
    private const int MaxFailedAttempts = 5;
    private const int LockoutMinutes = 15;
    private const int DefaultStepUpMinutes = 15;

    public static WebApplication MapMfaEndpoints(this WebApplication app)
    {
        app.MapGet("/accounts/{accountId:guid}/mfa", GetStatus).RequireAuthorization().RequireRateLimiting("auth");
        app.MapPost("/accounts/{accountId:guid}/mfa/enroll/start", EnrollStart).RequireAuthorization().RequireRateLimiting("auth");
        app.MapPost("/accounts/{accountId:guid}/mfa/enroll/confirm", EnrollConfirm).RequireAuthorization().RequireRateLimiting("auth");
        app.MapPost("/accounts/{accountId:guid}/mfa/verify", Verify).RequireAuthorization().RequireRateLimiting("auth");
        app.MapPost("/accounts/{accountId:guid}/mfa/backup-codes/regenerate", RegenerateBackupCodes).RequireAuthorization().RequireRateLimiting("auth");
        app.MapPost("/accounts/{accountId:guid}/mfa/disable", Disable).RequireAuthorization().RequireRateLimiting("auth");
        return app;
    }

    // -----------------------------------------------------------------------
    // GET /accounts/{accountId}/mfa
    // -----------------------------------------------------------------------
    private static async Task<IResult> GetStatus(
        Guid accountId, ClaimsPrincipal user, AppDbContext db, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        var mfa = await db.AccountMfas.AsNoTracking().SingleOrDefaultAsync(m => m.AccountId == accountId, ct);
        var backupCodesRemaining = mfa is null ? 0 : await db.AccountMfaBackupCodes
            .CountAsync(c => c.AccountId == accountId && c.UsedAt == null, ct);

        return Results.Ok(new MfaStatusResponse(mfa?.Enabled ?? false, mfa?.ConfirmedAt, backupCodesRemaining));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/mfa/enroll/start
    // -----------------------------------------------------------------------
    private static async Task<IResult> EnrollStart(
        Guid accountId, EnrollStartRequest request, ClaimsPrincipal user, AppDbContext db,
        MfaEncryptionService encryption, TimeProvider clock, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();
        if (!encryption.IsConfigured) return NotConfigured();

        var account = await db.Accounts.AsNoTracking().SingleOrDefaultAsync(a => a.AccountId == accountId, ct);
        if (account is null) return Results.NotFound(new { error = "Account not found." });

        // Whoever starts enrollment is handed the secret, so a stolen device JWT
        // alone must not be enough: the thief could enrol THEIR authenticator and
        // lock the real owner out of organization administration. Same proof of
        // the account's auth key that linking a device and deleting the account
        // require.
        byte[] authKey;
        try { authKey = Convert.FromBase64String(request.AuthKey ?? ""); }
        catch (FormatException) { return Results.Forbid(); }
        if (authKey.Length == 0 || !await AccountEndpoints.VerifyAuthKeyAsync(authKey, account.AuthKeyHash))
            return Results.Forbid();

        var mfa = await db.AccountMfas.SingleOrDefaultAsync(m => m.AccountId == accountId, ct);
        if (mfa is { Enabled: true }) return AlreadyEnabled();
        // A restart must not be a way around the lockout below.
        if (mfa?.LockedUntil is { } startLockedUntil && startLockedUntil > clock.GetUtcNow()) return Locked();

        var secret = RandomNumberGenerator.GetBytes(SecretBytes);
        var encryptedSecret = encryption.Encrypt(secret);

        if (mfa is null)
        {
            db.AccountMfas.Add(new AccountMfa { AccountId = accountId, EncryptedSecret = encryptedSecret });
        }
        else
        {
            // Re-starting before confirm replaces the pending secret and its
            // replay state. The failure counter is deliberately KEPT: every
            // guess has the same 3-in-a-million chance whatever the secret,
            // so resetting it here would turn start-guess-start into an
            // unlimited guessing loop.
            mfa.EncryptedSecret = encryptedSecret;
            mfa.LastAcceptedStep = null;
        }
        await db.SaveChangesAsync(ct);

        var secretBase32 = Base32.Encode(secret);
        var otpauthUri = $"otpauth://totp/{Uri.EscapeDataString($"Jay:{account.Email}")}" +
                          $"?secret={secretBase32}&issuer=Jay&algorithm=SHA1&digits=6&period=30";

        return Results.Ok(new EnrollStartResponse(secretBase32, otpauthUri));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/mfa/enroll/confirm
    // -----------------------------------------------------------------------
    private static async Task<IResult> EnrollConfirm(
        Guid accountId, EnrollConfirmRequest request, ClaimsPrincipal user,
        AppDbContext db, MfaEncryptionService encryption, TotpService totp, TimeProvider clock, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();
        if (!encryption.IsConfigured) return NotConfigured();

        var mfa = await db.AccountMfas.SingleOrDefaultAsync(m => m.AccountId == accountId, ct);
        if (mfa is null || mfa.Enabled) return mfa is { Enabled: true } ? AlreadyEnabled() : ConfirmInvalidCode();
        // Same lockout as verify: confirm is a code check like any other.
        if (mfa.LockedUntil is { } lockedUntil && lockedUntil > clock.GetUtcNow()) return Locked();

        var secret = encryption.Decrypt(mfa.EncryptedSecret);
        var step = totp.MatchStep(secret, request.Code ?? "");
        if (step is null)
        {
            // RegisterFailureAsync answers with verify's 401; confirm keeps its
            // documented 400 unless this very failure tripped the lock.
            var failure = await RegisterFailureAsync(db, accountId, clock, ct);
            return failure is IStatusCodeHttpResult { StatusCode: StatusCodes.Status429TooManyRequests }
                ? failure
                : ConfirmInvalidCode();
        }

        var codes = Enumerable.Range(0, MfaBackupCodes.CodeCount).Select(_ => MfaBackupCodes.Generate()).ToList();
        foreach (var code in codes)
            db.AccountMfaBackupCodes.Add(new AccountMfaBackupCode { AccountId = accountId, CodeHash = MfaBackupCodes.Hash(code) });

        mfa.Enabled = true;
        mfa.ConfirmedAt = DateTimeOffset.UtcNow;
        mfa.LastAcceptedStep = step;
        mfa.FailedAttempts = 0;
        mfa.LockedUntil = null;
        await db.SaveChangesAsync(ct);

        return Results.Ok(new EnrollConfirmResponse(codes));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/mfa/verify
    // -----------------------------------------------------------------------
    private static async Task<IResult> Verify(
        Guid accountId, VerifyRequest request, ClaimsPrincipal user, HttpContext http,
        AppDbContext db, MfaEncryptionService encryption, TotpService totp, JwtService jwtService,
        TimeProvider clock, IConfiguration configuration, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();
        if (!encryption.IsConfigured) return NotConfigured();

        var mfa = await db.AccountMfas.AsNoTracking().SingleOrDefaultAsync(m => m.AccountId == accountId, ct);
        if (mfa is not { Enabled: true }) return NotEnabled();
        if (mfa.LockedUntil is { } lockedUntil && lockedUntil > clock.GetUtcNow()) return Locked();

        var consumed = await TryConsumeCodeAsync(db, encryption, totp, mfa, request.Code, request.BackupCode, clock, ct);
        if (consumed.Failure is not null) return consumed.Failure;

        var deviceId = AccountEndpoints.CallerDeviceId(user)!.Value;
        var handle = user.FindFirst("handle")?.Value ?? "";
        var stepUpMinutes = configuration.GetValue<int?>("Mfa:StepUpMinutes") ?? DefaultStepUpMinutes;
        var (token, expiresAt) = jwtService.GenerateStepUpToken(
            deviceId, handle, accountId, TimeSpan.FromMinutes(stepUpMinutes), clock.GetUtcNow());

        return Results.Ok(new VerifyResponse(token, expiresAt));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/mfa/backup-codes/regenerate
    // -----------------------------------------------------------------------
    private static async Task<IResult> RegenerateBackupCodes(
        Guid accountId, ClaimsPrincipal user, AppDbContext db, TimeProvider clock, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();
        if (MfaAuthHelper.RequireStepUp(user, accountId, clock) is { } stepUpRequired) return stepUpRequired;

        var mfa = await db.AccountMfas.AsNoTracking().SingleOrDefaultAsync(m => m.AccountId == accountId, ct);
        if (mfa is not { Enabled: true }) return NotEnabled();

        // Regenerating invalidates every existing code, used or not — bulk
        // delete instead of loading+RemoveRange, same style as the atomic
        // updates elsewhere in this file.
        await db.AccountMfaBackupCodes.Where(c => c.AccountId == accountId).ExecuteDeleteAsync(ct);

        var codes = Enumerable.Range(0, MfaBackupCodes.CodeCount).Select(_ => MfaBackupCodes.Generate()).ToList();
        foreach (var code in codes)
            db.AccountMfaBackupCodes.Add(new AccountMfaBackupCode { AccountId = accountId, CodeHash = MfaBackupCodes.Hash(code) });
        await db.SaveChangesAsync(ct);

        return Results.Ok(new EnrollConfirmResponse(codes));
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/mfa/disable
    // -----------------------------------------------------------------------
    private static async Task<IResult> Disable(
        Guid accountId, DisableRequest request, ClaimsPrincipal user,
        AppDbContext db, MfaEncryptionService encryption, TotpService totp, TimeProvider clock, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();
        if (!encryption.IsConfigured) return NotConfigured();

        var mfa = await db.AccountMfas.SingleOrDefaultAsync(m => m.AccountId == accountId, ct);
        if (mfa is not { Enabled: true }) return NotEnabled();
        if (mfa.LockedUntil is { } lockedUntil && lockedUntil > clock.GetUtcNow()) return Locked();

        var consumed = await TryConsumeCodeAsync(db, encryption, totp, mfa, request.Code, null, clock, ct);
        if (consumed.Failure is not null) return consumed.Failure;

        // Cascade delete (AppDbContext.OnModelCreating) removes the backup
        // codes with the same call — an org admin who disables MFA immediately
        // re-locks their own privileged actions (N03b), by design.
        db.AccountMfas.Remove(mfa);
        await db.SaveChangesAsync(ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // Shared: validate a TOTP or backup code, applying replay/lockout rules.
    // Returns Failure = null on success. `mfa` may be stale (AsNoTracking) —
    // this method only issues its own atomic UPDATEs, it never calls
    // SaveChanges on the passed entity.
    // -----------------------------------------------------------------------
    private static async Task<(IResult? Failure, long? Step)> TryConsumeCodeAsync(
        AppDbContext db, MfaEncryptionService encryption, TotpService totp, AccountMfa mfa,
        string? code, string? backupCode, TimeProvider clock, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(backupCode))
        {
            var hash = MfaBackupCodes.Hash(backupCode);
            var redeemed = await db.AccountMfaBackupCodes
                .Where(c => c.AccountId == mfa.AccountId && c.CodeHash == hash && c.UsedAt == null)
                .ExecuteUpdateAsync(s => s.SetProperty(c => c.UsedAt, clock.GetUtcNow()), ct);

            if (redeemed == 0) return (await RegisterFailureAsync(db, mfa.AccountId, clock, ct), null);
            await ResetFailuresAsync(db, mfa.AccountId, ct);
            return (null, null);
        }

        if (string.IsNullOrWhiteSpace(code)) return (InvalidCode(), null);

        var secret = encryption.Decrypt(mfa.EncryptedSecret);
        var step = totp.MatchStep(secret, code);
        if (step is null) return (await RegisterFailureAsync(db, mfa.AccountId, clock, ct), null);

        // Reject replay atomically: only accept if this step is strictly
        // newer than the last accepted one for this account.
        var accepted = await db.AccountMfas
            .Where(m => m.AccountId == mfa.AccountId && (m.LastAcceptedStep == null || m.LastAcceptedStep < step))
            .ExecuteUpdateAsync(s => s
                .SetProperty(m => m.LastAcceptedStep, step)
                .SetProperty(m => m.FailedAttempts, 0)
                .SetProperty(m => m.LockedUntil, (DateTimeOffset?)null), ct);

        if (accepted == 0) return (Results.Conflict(new { error = "This code was already used.", code = "mfa_code_reused" }), null);
        return (null, step);
    }

    private static async Task<IResult> RegisterFailureAsync(AppDbContext db, Guid accountId, TimeProvider clock, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var lockoutAt = now.AddMinutes(LockoutMinutes);

        // Single atomic UPDATE: the increment and the lock decision happen
        // server-side in one statement, so two parallel wrong guesses cannot
        // both read "4 failures" and both slip past the 5th-failure lock.
        await db.AccountMfas.Where(m => m.AccountId == accountId)
            .ExecuteUpdateAsync(s => s
                .SetProperty(m => m.FailedAttempts, m => m.FailedAttempts + 1)
                .SetProperty(m => m.LockedUntil, m => m.FailedAttempts + 1 >= MaxFailedAttempts ? lockoutAt : m.LockedUntil), ct);

        var current = await db.AccountMfas.AsNoTracking().Where(m => m.AccountId == accountId)
            .Select(m => m.LockedUntil).SingleOrDefaultAsync(ct);
        return current is { } lockedUntil && lockedUntil > now ? Locked() : InvalidCode();
    }

    private static Task ResetFailuresAsync(AppDbContext db, Guid accountId, CancellationToken ct) =>
        db.AccountMfas.Where(m => m.AccountId == accountId)
            .ExecuteUpdateAsync(s => s.SetProperty(m => m.FailedAttempts, 0).SetProperty(m => m.LockedUntil, (DateTimeOffset?)null), ct);

    private static IResult NotConfigured() => Results.Json(
        new { error = "MFA is not configured on this server.", code = "mfa_not_configured" },
        statusCode: StatusCodes.Status503ServiceUnavailable);

    private static IResult AlreadyEnabled() => Results.Conflict(new { error = "MFA is already enabled.", code = "mfa_already_enabled" });

    private static IResult NotEnabled() => Results.Conflict(new { error = "MFA is not enabled for this account.", code = "mfa_not_enabled" });

    private static IResult InvalidCode() => Results.Json(
        new { error = "Invalid MFA code.", code = "mfa_invalid_code" }, statusCode: StatusCodes.Status401Unauthorized);

    private static IResult ConfirmInvalidCode() =>
        Results.BadRequest(new { error = "Invalid MFA code.", code = "mfa_invalid_code" });

    private static IResult Locked() => Results.Json(
        new { error = "Too many failed MFA attempts. Try again later.", code = "mfa_locked" },
        statusCode: StatusCodes.Status429TooManyRequests);
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record MfaStatusResponse(bool Enabled, DateTimeOffset? ConfirmedAt, int BackupCodesRemaining);
public record EnrollStartRequest(string? AuthKey);
public record EnrollStartResponse(string SecretBase32, string OtpauthUri);
public record EnrollConfirmRequest(string? Code);
public record EnrollConfirmResponse(List<string> BackupCodes);
public record VerifyRequest(string? Code, string? BackupCode);
public record VerifyResponse(string Token, DateTimeOffset ExpiresAt);
public record DisableRequest(string? Code);
