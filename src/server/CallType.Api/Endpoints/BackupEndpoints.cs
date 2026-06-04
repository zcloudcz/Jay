// ---------------------------------------------------------------------------
// BackupEndpoints.cs — Encrypted backup metadata management
// ---------------------------------------------------------------------------
// Clients periodically export their chat history as an encrypted blob and
// upload it to Azure Blob Storage. These endpoints manage the metadata only —
// actual blob upload/download is handled in Phase 6 (Azure Blob integration).
//
// The server never holds backup decryption keys. The passphrase-derived key
// (Argon2id) is generated and used entirely client-side. BlobPath is a
// deterministic path format so the client can construct the upload URL.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Endpoints;

public static class BackupEndpoints
{
    /// <summary>
    /// Registers all backup-related routes on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapBackupEndpoints(this WebApplication app)
    {
        app.MapPost("/backups", CreateBackup);
        app.MapGet("/backups/{accountId:guid}", ListBackups);
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /backups — Record backup metadata
    // -----------------------------------------------------------------------
    private static async Task<IResult> CreateBackup(
        CreateBackupRequest request,
        AppDbContext db,
        CancellationToken ct)
    {
        // Only registered users can create backups — anonymous devices have
        // no account to associate the backup with.
        var accountExists = await db.Accounts.AnyAsync(a => a.AccountId == request.AccountId, ct);
        if (!accountExists)
            return Results.NotFound(new { error = "Account not found." });

        if (request.SizeBytes <= 0)
            return Results.BadRequest(new { error = "SizeBytes must be positive." });

        var now = DateTimeOffset.UtcNow;

        // Deterministic blob path: the client uses the same pattern to construct
        // the upload URL. Timestamp format avoids filesystem-unfriendly characters.
        // Append a GUID to prevent same-second collisions — two near-simultaneous
        // backup requests from the same account would otherwise overwrite each other.
        var timestamp = now.ToString("yyyyMMddHHmmss");
        var blobPath = $"backups/{request.AccountId}/{timestamp}_{Guid.NewGuid():N}.enc";

        var backup = new Backup
        {
            AccountId = request.AccountId,
            BlobPath = blobPath,
            SizeBytes = request.SizeBytes,
            CreatedAt = now
        };

        db.Backups.Add(backup);
        await db.SaveChangesAsync(ct);

        return Results.Created(
            $"/backups/{request.AccountId}",
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
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record CreateBackupRequest(Guid AccountId, long SizeBytes);
public record CreateBackupResponse(long Id, string BlobPath);
public record BackupDto(long Id, string BlobPath, long SizeBytes, DateTimeOffset CreatedAt);
