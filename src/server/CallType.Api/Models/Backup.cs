// ---------------------------------------------------------------------------
// Backup.cs — Encrypted chat backup metadata
// ---------------------------------------------------------------------------
// Clients periodically export their chat history as an encrypted blob and
// upload it to Azure Blob Storage. This entity tracks the metadata (path,
// size, timestamp) so the server can list backups for the account without
// scanning the blob container. The actual backup content is opaque — the
// server never holds the decryption key.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

/// <summary>
/// Lifecycle state of a backup row. Drives the reservation -> upload ->
/// completed -> deleting -> removed state machine documented at the top of
/// BackupStorageService.cs. "Removed" has no enum value — once a Deleting row's
/// blob is confirmed gone, the row is hard-deleted rather than kept as a tombstone.
/// </summary>
public enum BackupStatus
{
    /// <summary>Quota slot reserved, blob upload not yet confirmed. Expires via ReservationExpiresAt.</summary>
    Reserved,

    /// <summary>Blob upload confirmed — a real, restorable backup.</summary>
    Completed,

    /// <summary>Marked for deletion; blob removal in progress or pending retry.</summary>
    Deleting
}

public class Backup
{
    /// <summary>
    /// Server-assigned surrogate key, auto-incremented.
    /// </summary>
    public long Id { get; set; }

    public Guid AccountId { get; set; }

    /// <summary>
    /// Relative path within Azure Blob Storage (e.g. "backups/{accountId}/{timestamp}.enc").
    /// </summary>
    public string BlobPath { get; set; } = string.Empty;

    /// <summary>
    /// Backup size in bytes. Stored here to enforce per-account quota limits
    /// without querying blob storage. For a Reserved row this is the size
    /// requested at reservation time (from Content-Length), not yet confirmed.
    /// </summary>
    public long SizeBytes { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public BackupStatus Status { get; set; } = BackupStatus.Reserved;

    /// <summary>
    /// For Reserved rows: when the reservation expires if never confirmed
    /// (crash between reservation and blob upload). BackupCleanupService
    /// deletes rows past this point — they never became real quota consumers
    /// since no blob was ever confirmed uploaded under their path.
    /// Null once the row reaches Completed.
    /// </summary>
    public DateTimeOffset? ReservationExpiresAt { get; set; }

    // Navigation property
    public Account Account { get; set; } = null!;
}
