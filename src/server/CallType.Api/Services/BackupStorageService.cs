// ---------------------------------------------------------------------------
// BackupStorageService.cs — Backup quota reservation + lifecycle (K03 / D02)
// ---------------------------------------------------------------------------
// State machine (a Backup row moves left to right; a crash between any two
// states must be safely recoverable — either resumed or cleaned up by
// BackupCleanupService, never left double-counting quota or orphaning a blob):
//
//   [reserve]                 [confirm]                    [begin-delete]        [confirm-delete]
//   -- tx: lock account,  -->  Reserved  -- blob upload -->  Completed  -- user -->  Deleting  -- blob
//      count+sum quota,        (row exists,   succeeds,      (row is a           requests      delete
//      insert Reserved row)     no blob yet)   row updated    real, listable      deletion      succeeds -->
//                                                             backup)                            row hard-deleted
//
// Crash points and how they are handled:
//   - Crash after reserve, before blob upload starts / before confirm:
//     row stays Reserved with ReservationExpiresAt in the near future. No blob
//     was ever created under that row's path, so there is nothing to delete —
//     BackupCleanupService simply deletes the row once ReservationExpiresAt
//     has passed. Quota counts Reserved rows, so no other upload can double
//     that space until either confirm or expiry frees it.
//   - Crash after blob upload succeeds, before confirm (DB write lost):
//     the blob is orphaned (uploaded but no Completed row references it).
//     Same as above: the Reserved row expires and is deleted; the leftover
//     blob is a provably-orphaned object because nothing in the DB claims
//     its path once the reservation is gone. Cleanup deletes the blob for
//     any Reserved row it evicts (best-effort — a missing blob is not an error).
//   - Crash after begin-delete (row is Deleting), before blob deleted:
//     row stays Deleting. Quota still counts it (freed only after confirmed
//     blob deletion, per K03) — a retry of the delete (explicit or via
//     cleanup) re-attempts the same blob deletion; deleting an already-gone
//     blob is treated as success (idempotent).
//   - Crash after blob deleted, before row removed: cleanup finds a Deleting
//     row, tries the blob delete again (Azure returns 404 -> treated as
//     already-done), then removes the row.
//
// Transaction boundaries:
//   - Reservation: a single DB transaction takes a Postgres advisory xact lock
//     (serializes concurrent reservations cluster-wide — see ponytail note
//     below), re-checks quota under that lock, and inserts the Reserved row.
//     The blob upload itself happens AFTER this transaction commits, so the
//     lock is held only for a few small SELECTs/INSERT, not for the upload.
//   - Confirm / begin-delete / confirm-delete: single-row UPDATE/DELETE, no
//     multi-statement transaction needed — each is naturally atomic.
// ---------------------------------------------------------------------------

using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Configuration;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace CallType.Api.Services;

public enum ReservationResult
{
    Reserved,
    AccountNotFound,
    QuotaExceeded
}

public record ReservationOutcome(ReservationResult Result, Backup? Backup);

public class BackupStorageService(AppDbContext db, IOptions<BackupLimitsOptions> limitsOptions)
{
    // How long a reservation may sit unconfirmed before it is considered
    // abandoned (crashed upload) and reclaimed by BackupCleanupService.
    // Generous enough for a slow upload of MaxFileBytes over a poor mobile
    // connection, short enough that a crash doesn't block quota for long.
    public static readonly TimeSpan ReservationTtl = TimeSpan.FromMinutes(10);

    private readonly BackupLimitsOptions _limits = limitsOptions.Value;

    /// <summary>
    /// Reserves quota for an upload of <paramref name="requestedBytes"/> before
    /// any blob I/O happens. Reserving first (rather than counting after upload)
    /// is what makes concurrent uploads racing for the last slot resolve to
    /// exactly one winner instead of both succeeding and busting the quota.
    /// </summary>
    public async Task<ReservationOutcome> ReserveAsync(Guid accountId, long requestedBytes, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);

        // ponytail: a single global advisory lock serializes ALL backup
        // reservations across every account, not just this one. Simplest
        // correct thing for the expected write volume (a handful of backups
        // per user per day); upgrade to per-account locks if this becomes a
        // throughput bottleneck.
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"SELECT pg_advisory_xact_lock(hashtext('backup-quota'))", ct);

        var accountExists = await db.Accounts.AnyAsync(a => a.AccountId == accountId, ct);
        if (!accountExists) return new ReservationOutcome(ReservationResult.AccountNotFound, null);

        // "Outstanding" = still counts against quota: Reserved (in-flight or
        // abandoned-but-not-yet-expired), Completed (real backups), and
        // Deleting (not freed until blob deletion is confirmed).
        var outstanding = db.Backups.Where(b =>
            b.Status == BackupStatus.Completed ||
            b.Status == BackupStatus.Deleting ||
            (b.Status == BackupStatus.Reserved && b.ReservationExpiresAt > DateTimeOffset.UtcNow));

        var accountCount = await outstanding.CountAsync(b => b.AccountId == accountId, ct);
        if (accountCount >= _limits.MaxPerAccount)
            return new ReservationOutcome(ReservationResult.QuotaExceeded, null);

        var totalBytes = await outstanding.SumAsync(b => (long?)b.SizeBytes, ct) ?? 0;
        if (totalBytes + requestedBytes > _limits.MaxTotalBytes)
            return new ReservationOutcome(ReservationResult.QuotaExceeded, null);

        var now = DateTimeOffset.UtcNow;
        var timestamp = now.ToString("yyyyMMddHHmmss");
        var blobPath = $"backups/{accountId}/{timestamp}_{Guid.NewGuid():N}.enc";

        var backup = new Backup
        {
            AccountId = accountId,
            BlobPath = blobPath,
            SizeBytes = requestedBytes,
            CreatedAt = now,
            Status = BackupStatus.Reserved,
            ReservationExpiresAt = now + ReservationTtl
        };
        db.Backups.Add(backup);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return new ReservationOutcome(ReservationResult.Reserved, backup);
    }

    /// <summary>Blob upload succeeded — the reservation becomes a real backup.</summary>
    public async Task ConfirmUploadAsync(long backupId, long actualBytes, CancellationToken ct)
    {
        var rows = await db.Backups.Where(b => b.Id == backupId)
            .ExecuteUpdateAsync(s => s
                .SetProperty(b => b.Status, BackupStatus.Completed)
                .SetProperty(b => b.SizeBytes, actualBytes)
                .SetProperty(b => b.ReservationExpiresAt, (DateTimeOffset?)null), ct);
        if (rows == 0)
            throw new InvalidOperationException($"Backup reservation {backupId} not found when confirming upload.");
    }

    /// <summary>Blob upload failed immediately — release the reservation right away
    /// instead of waiting out the full TTL. Best-effort; if this doesn't run
    /// (process crash), the TTL-based cleanup still reclaims it.</summary>
    public Task AbortReservationAsync(long backupId, CancellationToken ct) =>
        db.Backups.Where(b => b.Id == backupId && b.Status == BackupStatus.Reserved)
            .ExecuteDeleteAsync(ct);
}
