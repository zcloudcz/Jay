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
    /// If the oldest un-acked QueuedMessage addressed to the auditor is older
    /// than this, the auditor is considered stuck and business messaging
    /// fails closed. Default 24 h: far below the 30-day TTL after which queued
    /// copies (and with them archive records) would be lost for good, far above
    /// any restart, upgrade or overnight outage of the archiver.
    /// </summary>
    public int AuditorMaxBacklogAgeSeconds { get; set; } = 86400;

    /// <summary>
    /// P1 (OrgCommunicationPolicy): how long a device-pair "allowed/blocked"
    /// verdict is cached. Default 30 s — long enough to matter on the hot 1:1
    /// send path, short enough that flipping the org policy takes effect
    /// quickly. Configurable so integration tests that flip the flag mid-test
    /// can set it to 0 instead of waiting out a real cache window.
    /// </summary>
    public int PolicyCacheSeconds { get; set; } = 30;
}
