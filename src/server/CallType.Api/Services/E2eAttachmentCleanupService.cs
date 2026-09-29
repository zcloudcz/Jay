// ---------------------------------------------------------------------------
// E2eAttachmentCleanupService.cs — expiry and blob deletion (stream M2) — X0 STUB
// ---------------------------------------------------------------------------
// Stream M2 (package M2-3) implements the three idempotent steps every 10 min
// (expired -> Deleting, Deleting -> blob gone -> Deleted, drop 24 h old
// tombstones) following the BackupCleanupService pattern. X0 registers the
// hosted service so wave 1 does not touch Program.cs for it.
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

public class E2eAttachmentCleanupService : BackgroundService
{
    // Returns immediately — until M2-3 no upload endpoint exists, so the only
    // rows that can appear are those GDPR deletion marks as Deleting, and
    // those have no blob behind them yet.
    protected override Task ExecuteAsync(CancellationToken stoppingToken) => Task.CompletedTask;

    /// <summary>One cleanup pass; the test seam M2-3's tests call directly.</summary>
    internal Task RunOnceAsync(CancellationToken ct) => Task.CompletedTask;
}
