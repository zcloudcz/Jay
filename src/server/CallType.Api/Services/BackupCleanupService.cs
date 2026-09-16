// ---------------------------------------------------------------------------
// BackupCleanupService.cs — Reclaims abandoned reservations, finishes deletes
// ---------------------------------------------------------------------------
// Two independent, idempotent, re-runnable jobs (see the state-machine comment
// at the top of BackupStorageService.cs):
//   1. Reserved rows whose ReservationExpiresAt has passed never got a
//      confirmed blob under their path (the row is deleted BEFORE any blob
//      upload could complete, or the process crashed before confirming) —
//      delete the row, and best-effort delete a same-path blob in case the
//      upload actually finished but the confirm write was lost.
//   2. Deleting rows are a delete that started but didn't finish (explicit
//      DELETE endpoint crashed, or a previous cleanup pass was interrupted) —
//      retry the blob delete, then remove the row. Deleting an already-gone
//      blob is treated as success, so this is safe to re-run indefinitely.
// Batched (TakeAsync) so a large backlog doesn't do unbounded work in one pass.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using CallType.Api.Data;
using CallType.Api.Models;
using Microsoft.EntityFrameworkCore;

namespace CallType.Api.Services;

public class BackupCleanupService(
    IServiceScopeFactory scopeFactory,
    ILogger<BackupCleanupService> logger) : BackgroundService
{
    private static readonly TimeSpan CleanupInterval = TimeSpan.FromMinutes(5);
    private const int BatchSize = 100;
    private const string ContainerName = "backups";

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("BackupCleanupService started. Cleanup interval: {Interval}", CleanupInterval);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunOnceAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Error during backup cleanup pass");
            }

            await Task.Delay(CleanupInterval, stoppingToken);
        }
    }

    internal async Task RunOnceAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var blobService = scope.ServiceProvider.GetRequiredService<BlobServiceClient>();
        var container = blobService.GetBlobContainerClient(ContainerName);

        await CleanupExpiredReservationsAsync(db, container, ct);
        await CleanupPendingDeletesAsync(db, container, ct);
    }

    private static async Task CleanupExpiredReservationsAsync(AppDbContext db, BlobContainerClient container, CancellationToken ct)
    {
        var expired = await db.Backups
            .Where(b => b.Status == BackupStatus.Reserved && b.ReservationExpiresAt < DateTimeOffset.UtcNow)
            .OrderBy(b => b.Id)
            .Take(BatchSize)
            .ToListAsync(ct);

        foreach (var backup in expired)
        {
            await TryDeleteBlobAsync(container, backup.BlobPath, ct);
            db.Backups.Remove(backup);
        }

        if (expired.Count > 0) await db.SaveChangesAsync(ct);
    }

    private static async Task CleanupPendingDeletesAsync(AppDbContext db, BlobContainerClient container, CancellationToken ct)
    {
        var pending = await db.Backups
            .Where(b => b.Status == BackupStatus.Deleting)
            .OrderBy(b => b.Id)
            .Take(BatchSize)
            .ToListAsync(ct);

        foreach (var backup in pending)
        {
            await TryDeleteBlobAsync(container, backup.BlobPath, ct);
            db.Backups.Remove(backup);
        }

        if (pending.Count > 0) await db.SaveChangesAsync(ct);
    }

    /// <summary>Deletes the blob at BlobPath (stripping the container prefix).
    /// A missing blob is not an error — deletion is idempotent by design.</summary>
    private static async Task TryDeleteBlobAsync(BlobContainerClient container, string blobPath, CancellationToken ct)
    {
        var relativePath = blobPath.StartsWith($"{ContainerName}/")
            ? blobPath[(ContainerName.Length + 1)..]
            : blobPath;

        // If this throws, the caller's loop/SaveChanges is skipped for this
        // batch, so the row is retried on the next pass — no partial state.
        await container.GetBlobClient(relativePath).DeleteIfExistsAsync(cancellationToken: ct);
    }
}
