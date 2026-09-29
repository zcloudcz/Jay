// ---------------------------------------------------------------------------
// AttachmentsOptions.cs — limits for end-to-end encrypted attachment blobs
// ---------------------------------------------------------------------------
// Bound from the "Attachments" configuration section (Attachments__* env vars)
// through the DI-resolved IConfiguration, like BusinessOptions, so integration
// tests can lower the limits. Values and reasoning:
// docs/superpowers/plans/2026-09-29-gap-media.md §4.2 (stream M2, package M2-3).
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class AttachmentsOptions
{
    public const string SectionName = "Attachments";

    /// <summary>100 MiB of media + 64 KiB headroom for the per-segment GCM tags.</summary>
    public long MaxCiphertextBytes { get; set; } = 104_923_136;

    /// <summary>
    /// 64 × (65 536 + 16): one upload chunk is exactly 64 whole cipher segments,
    /// and 4 MiB stays well under Kestrel's 10 MB body limit.
    /// </summary>
    public int ChunkBytes { get; set; } = 4_195_328;

    /// <summary>Committed blobs are deleted this many days after commit (same TTL as the message queue).</summary>
    public int RetentionDays { get; set; } = 30;

    /// <summary>An upload that is not committed within this window is abandoned and cleaned up.</summary>
    public int UploadWindowHours { get; set; } = 24;

    /// <summary>1 GiB of ciphertext per device per rolling 24 h.</summary>
    public long MaxBytesPerDevicePerDay { get; set; } = 1_073_741_824;

    public int MaxUploadsPerDevicePerDay { get; set; } = 1000;

    /// <summary>Concurrent unfinished uploads per device.</summary>
    public int MaxPendingUploadsPerDevice { get; set; } = 20;

    /// <summary>50 GiB per rolling 24 h across the whole installation (storage cost guard).</summary>
    public long MaxTotalBytesPerDay { get; set; } = 53_687_091_200;
}
