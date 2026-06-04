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
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

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
            .RequireAuthorization();

        app.MapGet("/backups/{accountId:guid}", ListBackups).RequireAuthorization();
        app.MapGet("/backups/{accountId:guid}/{backupId:long}", DownloadBackup).RequireAuthorization();
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /backups/{accountId} — Upload encrypted backup file
    // -----------------------------------------------------------------------
    private static async Task<IResult> UploadBackup(
        Guid accountId,
        IFormFile file,
        AppDbContext db,
        BlobServiceClient blobService,
        CancellationToken ct)
    {
        // Only registered users can create backups — anonymous devices have
        // no account to associate the backup with.
        var accountExists = await db.Accounts.AnyAsync(a => a.AccountId == accountId, ct);
        if (!accountExists)
            return Results.NotFound(new { error = "Account not found." });

        if (file.Length <= 0)
            return Results.BadRequest(new { error = "File must not be empty." });

        var now = DateTimeOffset.UtcNow;

        // Deterministic blob path: timestamp + GUID prevents same-second collisions
        // from concurrent backup uploads by the same account.
        var timestamp = now.ToString("yyyyMMddHHmmss");
        var blobPath = $"{accountId}/{timestamp}_{Guid.NewGuid():N}.enc";

        // Create the container if it doesn't exist. CreateIfNotExistsAsync is
        // idempotent — safe to call on every upload without a separate init step.
        var containerClient = blobService.GetBlobContainerClient(ContainerName);
        await containerClient.CreateIfNotExistsAsync(cancellationToken: ct);

        // Upload the encrypted file as a blob. Overwrite is false because the
        // GUID in the path guarantees uniqueness — a collision would indicate a bug.
        var blobClient = containerClient.GetBlobClient(blobPath);
        await using var stream = file.OpenReadStream();
        await blobClient.UploadAsync(stream, overwrite: false, cancellationToken: ct);

        // Store metadata in PostgreSQL so we can list/query backups without
        // scanning the blob container (which is slow and costs per-operation).
        var backup = new Backup
        {
            AccountId = accountId,
            BlobPath = $"{ContainerName}/{blobPath}",
            SizeBytes = file.Length,
            CreatedAt = now
        };

        db.Backups.Add(backup);
        await db.SaveChangesAsync(ct);

        return Results.Created(
            $"/backups/{accountId}",
            new CreateBackupResponse(backup.Id, backup.BlobPath));
    }

    // -----------------------------------------------------------------------
    // GET /backups/{accountId} — List backups for an account
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListBackups(
        Guid accountId,
        AppDbContext db,
        CancellationToken ct)
    {
        // Return newest first — most recent backup is the most likely restore target.
        var backups = await db.Backups
            .Where(b => b.AccountId == accountId)
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
        AppDbContext db,
        BlobServiceClient blobService,
        CancellationToken ct)
    {
        // Verify the backup belongs to the requested account — prevents
        // authenticated users from downloading other accounts' backups
        // by guessing backup IDs.
        var backup = await db.Backups
            .FirstOrDefaultAsync(b => b.Id == backupId && b.AccountId == accountId, ct);

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
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record CreateBackupResponse(long Id, string BlobPath);
public record BackupDto(long Id, string BlobPath, long SizeBytes, DateTimeOffset CreatedAt);
