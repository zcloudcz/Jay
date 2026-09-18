// ---------------------------------------------------------------------------
// BusinessOptions.cs — thresholds for the auditor fail-closed rule (W2-F)
// ---------------------------------------------------------------------------
// Bound from the "Business" configuration section (Business__* env vars, same
// double-underscore convention as the rest of the app). See
// AuditorLivenessService for how these are used.
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class BusinessOptions
{
    public const string SectionName = "Business";

    /// <summary>
    /// How long after a disconnect the auditor device is still treated as
    /// "alive" — so a routine archiver restart doesn't bounce business
    /// messages while it reconnects. 120 s default.
    /// </summary>
    public int AuditorDisconnectGraceSeconds { get; set; } = 120;

    /// <summary>
    /// If the oldest un-acked QueuedMessage addressed to the auditor is older
    /// than this, the auditor is considered stuck and business messaging
    /// fails closed. 300 s default.
    /// </summary>
    public int AuditorMaxBacklogAgeSeconds { get; set; } = 300;
}
