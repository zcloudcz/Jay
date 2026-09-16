// ---------------------------------------------------------------------------
// BackupEndpoints.cs — Encrypted backup upload/download via Azure Blob Storage
// ---------------------------------------------------------------------------
// Clients periodically export their chat history as an encrypted blob and
// upload it here. The server stores the file in Azure Blob Storage and tracks
// metadata (path, size, timestamp) in PostgreSQL for listing/lookup.
//
// The server never holds backup decryption keys. The passphrase-derived key
// (Argon2id) is generated and used entirely client-side. The .enc extension
// signals that the blob is an opaque encrypted payload.
//
// Upload uses IFormFile (multipart) rather than raw request body streaming
// because ASP.NET Core's model binding handles buffering, size limits, and
// content-type validation out of the box.
//
// Quota enforcement (K03) reserves a slot via BackupStorageService BEFORE the
// blob upload starts (see the state-machine comment in BackupStorageService.cs)
// so two concurrent uploads racing for the last slot cannot both succeed.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Configuration;
using Microsoft.Extensions.Options;

namespace CallType.Api.Endpoints;

public static class BackupEndpoints
{
    // Container name in Azure Blob Storage. Lowercase per Azure naming rules.
    private const string ContainerName = "backups";

    /// <summary>
    /// Registers all backup-related routes on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapBackupEndpoints(this WebApplication app)
    {
        // Upload requires DisableAntiforgery because multipart form posts
        // from non-browser clients (Flutter, curl) won't include an antiforgery token.
        app.MapPost("/backups/{accountId:guid}", UploadBackup)
            .DisableAntiforgery()
            .RequireAuthorization()
            .RequireRateLimiting("api");

        app.MapGet("/backups/{accountId:guid}", ListBackups).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/backups/{accountId:guid}/{backupId:long}", DownloadBackup).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/backups/{accountId:guid}/{backupId:long}", DeleteBackup).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /backups/{accountId} — Upload encrypted backup file
    // -----------------------------------------------------------------------
    private static async Task<IResult> UploadBackup(
        Guid accountId,
        IFormFile file,
        ClaimsPrincipal user,
        AppDbContext db,
        BlobServiceClient blobService,
        BackupStorageService storage,
        IOptions<BackupLimitsOptions> limitsOptions,
        CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        if (file.Length <= 0)
            return Results.BadRequest(new { error = "File must not be empty." });

        var limits = limitsOptions.Value;
        if (file.Length > limits.MaxFileBytes)
            return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);

        // Reserve quota BEFORE touching blob storage — see BackupStorageService
        // state-machine comment for why (concurrency safety, crash recovery).
        var reservation = await storage.ReserveAsync(accountId, file.Length, ct);
        switch (reservation.Result)
        {
            // Only registered users can create backups — anonymous devices have
            // no account to associate the backup with.
            case ReservationResult.AccountNotFound:
                return Results.NotFound(new { error = "Account not found." });
            case ReservationResult.QuotaExceeded:
                return Results.Conflict(new { error = "Backup quota exceeded.", code = "backup_quota_exceeded" });
        }

        var backup = reservation.Backup!;
        var relativePath = backup.BlobPath[(ContainerName.Length + 1)..];

        try
        {
            // Create the container if it doesn't exist. CreateIfNotExistsAsync is
            // idempotent — safe to call on every upload without a separate init step.
            var containerClient = blobService.GetBlobContainerClient(ContainerName);
            await containerClient.CreateIfNotExistsAsync(cancellationToken: ct);

            // Upload the encrypted file as a blob. Overwrite is false because the
            // GUID in the path guarantees uniqueness — a collision would indicate a bug.
            var blobClient = containerClient.GetBlobClient(relativePath);
            await using var stream = file.OpenReadStream();
            await blobClient.UploadAsync(stream, overwrite: false, cancellationToken: ct);
        }
        catch
        {
            // Upload failed — release the reservation immediately rather than
            // waiting out the TTL, so the account isn't stuck at quota for
            // no reason. If this process crashes before even reaching here,
            // BackupCleanupService reclaims the reservation once it expires.
            await storage.AbortReservationAsync(backup.Id, ct);
            throw;
        }

        await storage.ConfirmUploadAsync(backup.Id, file.Length, ct);

        return Results.Created(
            $"/backups/{accountId}",
            new CreateBackupResponse(backup.Id, backup.BlobPath));
    }

    // -----------------------------------------------------------------------
    // GET /backups/{accountId} — List backups for an account
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListBackups(
        Guid accountId,
        ClaimsPrincipal user,
        AppDbContext db,
        CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        // Only completed backups are real, restorable backups — Reserved and
        // Deleting rows are internal bookkeeping, not user-visible history.
        var backups = await db.Backups
            .Where(b => b.AccountId == accountId && b.Status == BackupStatus.Completed)
            .OrderByDescending(b => b.CreatedAt)
            .Select(b => new BackupDto(b.Id, b.BlobPath, b.SizeBytes, b.CreatedAt))
            .ToListAsync(ct);

        return Results.Ok(backups);
    }

    // -----------------------------------------------------------------------
    // GET /backups/{accountId}/{backupId} — Download encrypted backup file
    // -----------------------------------------------------------------------
    private static async Task<IResult> DownloadBackup(
        Guid accountId,
        long backupId,
        ClaimsPrincipal user,
        AppDbContext db,
        BlobServiceClient blobService,
        CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        // Verify the backup belongs to the requested account — prevents
        // authenticated users from downloading other accounts' backups
        // by guessing backup IDs.
        var backup = await db.Backups
            .FirstOrDefaultAsync(b => b.Id == backupId && b.AccountId == accountId && b.Status == BackupStatus.Completed, ct);

        if (backup is null)
            return Results.NotFound(new { error = "Backup not found." });

        // Extract the relative blob path by stripping the container prefix.
        // BlobPath format: "backups/{accountId}/{timestamp}_{guid}.enc"
        var relativePath = backup.BlobPath.StartsWith($"{ContainerName}/")
            ? backup.BlobPath[($"{ContainerName}/".Length)..]
            : backup.BlobPath;

        var containerClient = blobService.GetBlobContainerClient(ContainerName);
        var blobClient = containerClient.GetBlobClient(relativePath);

        // Stream the blob directly to the HTTP response — no buffering the
        // entire file in memory. Important for large backups (could be 100+ MB).
        var download = await blobClient.DownloadStreamingAsync(cancellationToken: ct);

        return Results.Stream(
            download.Value.Content,
            contentType: "application/octet-stream",
            fileDownloadName: $"backup_{backupId}.enc");
    }

    // -----------------------------------------------------------------------
    // DELETE /backups/{accountId}/{backupId} — Free a backup slot manually
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeleteBackup(
        Guid accountId,
        long backupId,
        ClaimsPrincipal user,
        AppDbContext db,
        BlobServiceClient blobService,
        CancellationToken ct)
    {
        // Own account owns no such backup id at all -> still 403 for a foreign
        // accountId (checked first, before we even look at the backup row).
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        var backup = await db.Backups.FirstOrDefaultAsync(b => b.Id == backupId, ct);

        // Backup never existed, or already fully removed by an earlier call —
        // both are indistinguishable from "gone", and repeating the request
        // must be idempotent per K03: 204 for the caller's own account context.
        if (backup is null) return Results.NoContent();

        // Exists, but belongs to a different account — do not leak existence
        // details and do not delete; 404 without touching the row.
        if (backup.AccountId != accountId) return Results.NotFound();

        // Mark-for-delete first (so a crash mid-way is recovered by
        // BackupCleanupService instead of silently losing the blob), THEN
        // delete the blob, THEN remove the row. Quota is freed only once the
        // row is gone (Deleting still counts), matching K03.
        if (backup.Status != BackupStatus.Deleting)
        {
            backup.Status = BackupStatus.Deleting;
            await db.SaveChangesAsync(ct);
        }

        var relativePath = backup.BlobPath.StartsWith($"{ContainerName}/")
            ? backup.BlobPath[($"{ContainerName}/".Length)..]
            : backup.BlobPath;
        var containerClient = blobService.GetBlobContainerClient(ContainerName);
        // Idempotent: a retry after a prior crash may find the blob already gone.
        await containerClient.GetBlobClient(relativePath).DeleteIfExistsAsync(cancellationToken: ct);

        db.Backups.Remove(backup);
        await db.SaveChangesAsync(ct);

        return Results.NoContent();
    }
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record CreateBackupResponse(long Id, string BlobPath);
public record BackupDto(long Id, string BlobPath, long SizeBytes, DateTimeOffset CreatedAt);
