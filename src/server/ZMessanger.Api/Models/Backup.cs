// ---------------------------------------------------------------------------
// Backup.cs — Encrypted chat backup metadata
// ---------------------------------------------------------------------------
// Clients periodically export their chat history as an encrypted blob and
// upload it to Azure Blob Storage. This entity tracks the metadata (path,
// size, timestamp) so the server can list backups for the account without
// scanning the blob container. The actual backup content is opaque — the
// server never holds the decryption key.
// ---------------------------------------------------------------------------

namespace ZMessanger.Api.Models;

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
    /// without querying blob storage.
    /// </summary>
    public long SizeBytes { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    // Navigation property
    public Account Account { get; set; } = null!;
}
