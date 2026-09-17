// ---------------------------------------------------------------------------
// ChannelReport.cs — Abuse report filed by a follower
// ---------------------------------------------------------------------------
// Read by the operator only (DB / notification to Channels:ReportNotifyEmail).
// ReporterDeviceId must never be returned to the channel's admins.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ChannelReport
{
    /// <summary>Server-assigned surrogate key, auto-incremented.</summary>
    public long Id { get; set; }

    public Guid ChannelId { get; set; }

    /// <summary>
    /// Reported post, or null when the whole channel is reported. Deliberately
    /// NOT a foreign key: the report must outlive the post when retention
    /// cleanup removes it.
    /// </summary>
    public Guid? PostId { get; set; }

    public Guid ReporterDeviceId { get; set; }

    /// <summary>Free-text reason from the reporter, max 512 chars.</summary>
    public string Reason { get; set; } = string.Empty;

    public DateTimeOffset CreatedAt { get; set; }

    // Navigation properties
    public Channel Channel { get; set; } = null!;
}
