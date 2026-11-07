// ---------------------------------------------------------------------------
// MediaOptions.cs - Limits and retention for end-to-end encrypted media
// ---------------------------------------------------------------------------
// Bound from the "Media" section (Media__MaxFileBytes=... as env vars).
// Contract and the reasoning behind every default:
// docs/superpowers/specs/2026-11-07-encrypted-media.md (sections 2.9, M5, M6).
// All byte limits are ENCRYPTED bytes (plaintext + 16-byte tag per chunk),
// because that is all the server ever sees.
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class MediaOptions
{
    public const string SectionName = "Media";

    /// <summary>Max encrypted size of one file. 5 GiB default (owner decision).</summary>
    public long MaxFileBytes { get; set; } = 5L * 1024 * 1024 * 1024;

    /// <summary>Lifetime of completed media, counted from completion. 72 h default (owner decision).</summary>
    public int RetentionHours { get; set; } = 72;

    /// <summary>Time to finish an upload, counted from creation. 24 h default.</summary>
    public int UploadWindowHours { get; set; } = 24;

    /// <summary>Uploading + completed (not expired) bytes per uploader device. 10 GiB default.</summary>
    public long MaxActiveBytesPerDevice { get; set; } = 10L * 1024 * 1024 * 1024;

    /// <summary>Declared bytes of uploads created by one device in a rolling 24 h. 20 GiB default.</summary>
    public long MaxDailyBytesPerDevice { get; set; } = 20L * 1024 * 1024 * 1024;

    /// <summary>Uploads created by one device in a rolling 24 h. 500 default.</summary>
    public int MaxUploadsPerDay { get; set; } = 500;

    /// <summary>
    /// Active bytes of the whole installation. 500 GiB default. Anonymous
    /// devices are free to create, so this, not the per-device caps, is what
    /// really bounds the storage bill.
    /// </summary>
    public long MaxTotalBytes { get; set; } = 500L * 1024 * 1024 * 1024;

    /// <summary>MediaCleanupService period. 10 minutes default.</summary>
    public int CleanupIntervalMinutes { get; set; } = 10;

    /// <summary>
    /// Chunk PUTs one device may have in flight. 8 default (the app uploads
    /// 2 chunks at a time per file). Each open PUT holds up to one chunk in
    /// memory, so this bounds what one (free, anonymous) device can pin.
    /// </summary>
    public int MaxConcurrentChunkUploadsPerDevice { get; set; } = 8;
}
