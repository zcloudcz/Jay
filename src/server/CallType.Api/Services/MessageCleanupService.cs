// ---------------------------------------------------------------------------
// MessageCleanupService.cs — Background job for expired message cleanup
// ---------------------------------------------------------------------------
// QueuedMessages have a 30-day TTL (ExpiresAt). While DequeueAsync in
// MessageQueueService cleans up expired messages per-recipient as a side
// effect, abandoned devices (never reconnect) would accumulate stale rows
// indefinitely. This background service runs hourly to bulk-delete all
// expired messages system-wide.
//
// Uses ExecuteDeleteAsync (EF Core bulk delete) which translates to a single
// DELETE FROM ... WHERE statement — no entity loading, no change tracking
// overhead. Efficient even with millions of expired rows.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

public class MessageCleanupService(
    IServiceScopeFactory scopeFactory,
    ILogger<MessageCleanupService> logger) : BackgroundService
{
    // Run every hour. Frequent enough to prevent storage bloat, infrequent
    // enough to avoid unnecessary DB load. The 30-day TTL is not time-critical
    // — a few hours of drift is irrelevant.
    private static readonly TimeSpan CleanupInterval = TimeSpan.FromHours(1);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("MessageCleanupService started. Cleanup interval: {Interval}", CleanupInterval);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await CleanupExpiredMessagesAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Log and continue — a transient DB failure should not kill the
                // background service. The next iteration will retry.
                logger.LogError(ex, "Error during expired message cleanup");
            }

            await Task.Delay(CleanupInterval, stoppingToken);
        }
    }

    /// <summary>
    /// Deletes all messages with ExpiresAt in the past. Runs as a single bulk
    /// SQL DELETE — no entity materialization or change tracking.
    /// </summary>
    private async Task CleanupExpiredMessagesAsync(CancellationToken ct)
    {
        // Create a fresh scope for each cleanup run. The BackgroundService
        // outlives any single scope, and DbContext must not be reused across
        // long-lived operations.
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var deletedCount = await db.QueuedMessages
            .Where(m => m.ExpiresAt < DateTimeOffset.UtcNow)
            .ExecuteDeleteAsync(ct);

        if (deletedCount > 0)
        {
            logger.LogInformation("Cleaned up {Count} expired message(s)", deletedCount);
        }
    }
}
