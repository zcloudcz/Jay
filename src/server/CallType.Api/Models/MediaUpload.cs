// ---------------------------------------------------------------------------
// MediaUpload.cs - Metadata of one end-to-end encrypted media blob
// ---------------------------------------------------------------------------
// Contract: docs/superpowers/specs/2026-11-07-encrypted-media.md section 2.
// The blob itself lives in container "media" under the name {Id}. The server
// stores nothing about the content (no name, no type, no recipients): only the
// encrypted size, the chunk layout needed to validate uploads, the uploader
// (for quotas and the uploader-only routes) and the lifetime.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

/// <summary>Lifecycle of a media row. Stored as text like BackupStatus.</summary>
public enum MediaStatus
{
    /// <summary>Created, chunks are being staged as uncommitted blocks. ExpiresAt = upload deadline.</summary>
    Uploading,

    /// <summary>Block list committed, downloadable until ExpiresAt.</summary>
    Completed,

    /// <summary>
    /// Cancelled by the uploader. The blob is gone, but the row is kept until
    /// CreatedAt + 24 h so the per-device daily caps cannot be bypassed by
    /// create + delete loops.
    /// </summary>
    Deleted
}

public class MediaUpload
{
    /// <summary>
    /// Server-generated random GUID v4. It doubles as the download capability
    /// (spec M3), so it must never be client-chosen or sequential.
    /// </summary>
    public Guid Id { get; set; } = Guid.NewGuid();

    /// <summary>
    /// The device that created the upload. Deliberately no FK to Device: the
    /// rows are deleted explicitly together with their blobs on device and
    /// account deletion, a DB cascade would orphan the blobs.
    /// </summary>
    public Guid UploaderDeviceId { get; set; }

    /// <summary>Encrypted size in bytes (plaintext + 16 per chunk).</summary>
    public long SizeBytes { get; set; }

    /// <summary>Encrypted chunk size in bytes (plaintext chunk + 16-byte tag).</summary>
    public int ChunkSize { get; set; }

    public MediaStatus Status { get; set; } = MediaStatus.Uploading;

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? CompletedAt { get; set; }

    /// <summary>
    /// While Uploading: the upload deadline (CreatedAt + UploadWindowHours).
    /// Once Completed: CompletedAt + RetentionHours. Cleanup deletes the blob
    /// and the row once this has passed.
    /// </summary>
    public DateTimeOffset ExpiresAt { get; set; }

    /// <summary>ceil(SizeBytes / ChunkSize).</summary>
    public int ChunkCount => (int)((SizeBytes + ChunkSize - 1) / ChunkSize);

    /// <summary>Exact encrypted length of chunk <paramref name="index"/> (the last one may be shorter).</summary>
    public int ExpectedChunkLength(int index) =>
        index == ChunkCount - 1 ? (int)(SizeBytes - (long)ChunkSize * (ChunkCount - 1)) : ChunkSize;
}
