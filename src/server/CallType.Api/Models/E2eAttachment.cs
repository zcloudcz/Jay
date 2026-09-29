// ---------------------------------------------------------------------------
// E2eAttachment.cs — metadata of one end-to-end encrypted attachment blob
// ---------------------------------------------------------------------------
// Media in chats (stream M2) travel as opaque ciphertext blobs in the Blob
// container "e2e-attachments"; the message itself only carries a reference
// (blobId + key, encrypted inside the Double Ratchet envelope). This row is
// the server's bookkeeping for quota, commit and cleanup — the server never
// holds the key, so it cannot read what it stores.
//
// Shape frozen in X0 (docs/superpowers/plans/2026-09-29-gap-media.md §4.1);
// the upload/download logic is stream M2's (package M2-3).
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

/// <summary>
/// Lifecycle of an attachment row: Uploading -> Committed -> Deleting -> Deleted.
/// Stored as text (like <see cref="BackupStatus"/>) so it is readable in psql.
/// </summary>
public enum E2eAttachmentStatus
{
    /// <summary>Reserved, chunks being uploaded; ExpiresAt = end of the upload window.</summary>
    Uploading,

    /// <summary>All chunks committed; downloadable until ExpiresAt (CommittedAt + retention).</summary>
    Committed,

    /// <summary>Marked for deletion; the cleanup service removes the blob (survives a crash).</summary>
    Deleting,

    /// <summary>
    /// Blob gone. The row is kept as a tombstone for 24 h so that
    /// "delete + upload again" still counts against the daily device quota.
    /// </summary>
    Deleted
}

public class E2eAttachment
{
    /// <summary>
    /// Primary key and blob name. Generated from 16 CSPRNG bytes, NOT
    /// Guid.NewGuid(): anyone who knows the id may download the ciphertext, so
    /// it works as a capability and must be unguessable.
    /// </summary>
    public Guid BlobId { get; set; }

    /// <summary>
    /// Uploading device. Deliberately NO foreign key to Device (same as
    /// QueuedMessage): the row must outlive a GDPR device deletion so the
    /// cleanup service still knows which blob to remove.
    /// </summary>
    public Guid UploaderDeviceId { get; set; }

    /// <summary>Declared size of the CIPHERTEXT in bytes.</summary>
    public long SizeBytes { get; set; }

    /// <summary>
    /// Chunk size in force when the upload started — stored per row so a
    /// configuration change cannot break an upload that is already in progress.
    /// </summary>
    public int ChunkSizeBytes { get; set; }

    public int ChunkCount { get; set; }

    public E2eAttachmentStatus Status { get; set; } = E2eAttachmentStatus.Uploading;

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? CommittedAt { get; set; }

    /// <summary>Uploading: end of the upload window. Committed: CommittedAt + RetentionDays.</summary>
    public DateTimeOffset ExpiresAt { get; set; }
}
