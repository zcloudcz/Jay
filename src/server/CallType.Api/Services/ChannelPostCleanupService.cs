// ---------------------------------------------------------------------------
// ChannelPostCleanupService.cs — Retention for public channel posts
// ---------------------------------------------------------------------------
// Channel posts are not store-and-forward: they stay on the server so offline
// followers can pull them later. This hourly job is the ONLY place retention is
// enforced — posts older than Channels:PostRetentionDays are hard-deleted
// together with their image blob (soft-deleted tombstones age out the same way).
//
// Modelled on MessageCleanupService, but it cannot be a single bulk DELETE:
// each post may own a blob that has to go first. So it works in batches:
//   1. read a batch of (PostId, AttachmentBlobPath),
//   2. delete the blobs (a missing blob is fine — idempotent),
//   3. bulk-delete those rows (reactions and votes cascade in the database).
// Blob before row: if blob deletion throws, the rows are still there and the
// next pass retries. The other order would orphan the blob forever.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using CallType.Api.Configuration;
using CallType.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace CallType.Api.Services;

public class ChannelPostCleanupService(
    IServiceScopeFactory scopeFactory,
    IOptions<ChannelsOptions> options,
    ILogger<ChannelPostCleanupService> logger) : BackgroundService
{
    /// <summary>Blob container holding the unencrypted channel images.</summary>
    public const string ContainerName = "channel-media";

    // Retention is counted in days, so hourly is plenty (same as MessageCleanupService).
    private static readonly TimeSpan CleanupInterval = TimeSpan.FromHours(1);

    // Bounds memory and the size of the "IN (...)" delete for one round trip.
    private const int BatchSize = 100;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("ChannelPostCleanupService started. Cleanup interval: {Interval}", CleanupInterval);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunOnceAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Log and continue — a transient DB/Blob failure should not kill
                // the background service. The next iteration will retry.
                logger.LogError(ex, "Error during channel post cleanup");
            }

            await Task.Delay(CleanupInterval, stoppingToken);
        }
    }

    /// <summary>One full cleanup pass. Internal so tests can run it without the timer loop.</summary>
    internal async Task<int> RunOnceAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var container = scope.ServiceProvider.GetRequiredService<BlobServiceClient>()
            .GetBlobContainerClient(ContainerName);

        var cutoff = DateTimeOffset.UtcNow.AddDays(-options.Value.PostRetentionDays);
        var total = 0;

        while (true)
        {
            var batch = await db.ChannelPosts
                .Where(p => p.CreatedAt < cutoff)
                .OrderBy(p => p.CreatedAt)
                .Take(BatchSize)
                .Select(p => new { p.PostId, p.AttachmentBlobPath })
                .ToListAsync(ct);

            if (batch.Count == 0) break;

            foreach (var post in batch)
            {
                if (post.AttachmentBlobPath is null) continue;

                // Accept the path with or without the container prefix, like
                // BackupCleanupService does for "backups/...".
                var relativePath = post.AttachmentBlobPath.StartsWith($"{ContainerName}/")
                    ? post.AttachmentBlobPath[(ContainerName.Length + 1)..]
                    : post.AttachmentBlobPath;
                await container.GetBlobClient(relativePath).DeleteIfExistsAsync(cancellationToken: ct);
            }

            var ids = batch.Select(p => p.PostId).ToList();
            total += await db.ChannelPosts.Where(p => ids.Contains(p.PostId)).ExecuteDeleteAsync(ct);

            if (batch.Count < BatchSize) break;
        }

        if (total > 0)
        {
            logger.LogInformation("Cleaned up {Count} channel post(s) past retention", total);
        }

        return total;
    }
}
