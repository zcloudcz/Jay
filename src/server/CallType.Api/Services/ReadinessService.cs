// ---------------------------------------------------------------------------
// ReadinessService.cs — checks whether backing dependencies are reachable
// ---------------------------------------------------------------------------
// Backs GET /health/ready (K05). Ready means PostgreSQL and the backup Blob
// container both answer within a fixed 5s total budget. Used to gate
// orchestrator traffic routing, NOT to drive automatic restarts — a single
// instance flapping restarts on every transient storage blip would make
// things worse, so this is intentionally a passive read, no side effects.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using CallType.Api.Data;

namespace CallType.Api.Services;

public class ReadinessService(AppDbContext db, BlobServiceClient blobService)
{
    private static readonly TimeSpan TotalTimeout = TimeSpan.FromSeconds(5);

    // Must match BackupEndpoints.ContainerName — readiness only needs to prove
    // the container is reachable, not create it (that stays the write path's job).
    private const string BackupContainerName = "backups";

    public async Task<bool> IsReadyAsync(CancellationToken cancellationToken = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TotalTimeout);

        try
        {
            var dbTask = db.Database.CanConnectAsync(cts.Token);
            var blobTask = blobService.GetBlobContainerClient(BackupContainerName).ExistsAsync(cts.Token);

            await Task.WhenAll(dbTask, blobTask);

            return dbTask.Result && blobTask.Result.Value;
        }
        catch (OperationCanceledException)
        {
            return false; // Timed out — treat as not ready.
        }
        catch (Exception)
        {
            // Any connectivity failure (network, auth, DNS) means not ready.
            // Deliberately swallowed: the /health/ready body must never leak
            // exception details or addresses.
            return false;
        }
    }
}
