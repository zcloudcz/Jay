// ---------------------------------------------------------------------------
// MediaCleanupService.cs - Retention for end-to-end encrypted media (spec M5)
// ---------------------------------------------------------------------------
// The server is a relay for media, not storage: completed media lives
// RetentionHours after completion, an unfinished upload UploadWindowHours
// after creation. Every CleanupIntervalMinutes this job:
//   1. Uploading/Completed rows with ExpiresAt <= now: delete blob (including
//      uncommitted blocks, see MediaBlobStore.DeleteWithBlocksAsync), then row.
//   2. Deleted rows past CreatedAt + 24 h (kept that long for the daily caps):
//      delete blob again (idempotent; retries a failed delete from the
//      DELETE endpoint), then row.
// Blob before row, per row: if a blob delete fails, that row stays and the
// next pass retries. The other order would orphan the blob forever.
// "now" comes from the injected TimeProvider so tests can move time.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Endpoints;
using CallType.Api.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace CallType.Api.Services;

public class MediaCleanupService(
    IServiceScopeFactory scopeFactory,
    IOptions<MediaOptions> options,
    TimeProvider clock,
    ILogger<MediaCleanupService> logger) : BackgroundService
{
    // Bounds memory and the size of one "IN (...)" delete.
    private const int BatchSize = 100;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = TimeSpan.FromMinutes(Math.Max(1, options.Value.CleanupIntervalMinutes));
        logger.LogInformation("MediaCleanupService started. Cleanup interval: {Interval}", interval);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunOnceAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A transient DB/Blob failure must not kill the service; next pass retries.
                logger.LogError(ex, "Error during media cleanup");
            }

            await Task.Delay(interval, clock, stoppingToken);
        }
    }

    /// <summary>One full cleanup pass; returns the number of rows removed. Public so tests can run it without the timer loop.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var blobService = scope.ServiceProvider.GetRequiredService<BlobServiceClient>();

        var now = clock.GetUtcNow();
        var deletedCutoff = now - MediaEndpoints.DailyWindow;
        var total = 0;
        var failedIds = new HashSet<Guid>();

        while (true)
        {
            var batch = await db.MediaUploads
                .Where(m => !failedIds.Contains(m.Id))
                .Where(m => (m.Status != MediaStatus.Deleted && m.ExpiresAt <= now) ||
                            (m.Status == MediaStatus.Deleted && m.CreatedAt <= deletedCutoff))
                .OrderBy(m => m.ExpiresAt)
                .Take(BatchSize)
                .Select(m => m.Id)
                .ToListAsync(ct);
            if (batch.Count == 0) break;

            var removable = new List<Guid>();
            foreach (var id in batch)
            {
                try
                {
                    await MediaBlobStore.DeleteWithBlocksAsync(MediaBlobStore.GetBlob(blobService, id), ct);
                    removable.Add(id);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // Row stays, so the next pass retries; skip it for the rest
                    // of this pass so the loop cannot spin on it.
                    failedIds.Add(id);
                    logger.LogWarning(ex, "Media blob {MediaId} could not be deleted; will retry", id);
                }
            }

            if (removable.Count > 0)
                total += await db.MediaUploads.Where(m => removable.Contains(m.Id)).ExecuteDeleteAsync(ct);

            if (batch.Count < BatchSize) break;
        }

        if (total > 0) logger.LogInformation("Cleaned up {Count} media upload(s)", total);
        return total;
    }
}
