// ---------------------------------------------------------------------------
// ChannelsOptions.cs — Configuration for public channels
// ---------------------------------------------------------------------------
// Bound from the "Channels" configuration section (Channels__PostRetentionDays
// etc. as env vars, same double-underscore convention as the rest of the app).
// See docs/superpowers/plans/2026-09-16-channels.md §7 for where the defaults
// come from.
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class ChannelsOptions
{
    public const string SectionName = "Channels";

    /// <summary>
    /// Posts older than this are hard-deleted (with their image) by
    /// ChannelPostCleanupService. 90 days default. Retention is global on
    /// purpose — do not hardcode it anywhere else, per-customer retention may
    /// come later.
    /// </summary>
    public int PostRetentionDays { get; set; } = 90;

    /// <summary>Max number of live (not deleted) channels one owner may have. 5 default.</summary>
    public int MaxOwnedPerDevice { get; set; } = 5;

    /// <summary>Max size of a post image, in bytes. 2 MiB default. There is no video in v1.</summary>
    public long MaxImageBytes { get; set; } = 2 * 1024 * 1024;

    /// <summary>
    /// Operator address notified about new ChannelReports. Empty = reports are
    /// only stored and logged.
    /// </summary>
    public string ReportNotifyEmail { get; set; } = "";

    /// <summary>
    /// At most one "new post" push per channel within this window, so a chatty
    /// channel cannot spam followers' lock screens. 10 minutes default.
    /// </summary>
    public int PushThrottleMinutes { get; set; } = 10;
}
