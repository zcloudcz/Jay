// ---------------------------------------------------------------------------
// ChannelReport.cs — Abuse report filed by a follower
// ---------------------------------------------------------------------------
// Read by the operator only (operator web /admin, see ModerationEndpoints).
// ReporterDeviceId must never be returned to the channel's admins NOR to the
// operator: the operator sees category, reason and the contact e-mail the
// reporter chose to give, never who reported (moderation design, Security).
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

    /// <summary>
    /// "illegal" | "terms" | "spam" (DSA Art. 16(2): the notice says what
    /// kind of problem it is). Old clients send no category, so the column
    /// defaults to "terms".
    /// </summary>
    public string Category { get; set; } = "terms";

    /// <summary>
    /// Optional reporter e-mail (max 254) for a manual reply by the operator.
    /// There is no mail sender in this API, so this is the only way an
    /// outcome can reach a reporter outside the app.
    /// </summary>
    public string? ContactEmail { get; set; }

    /// <summary>Good-faith statement (DSA Art. 16(2)(d)); required for "illegal".</summary>
    public bool GoodFaith { get; set; }

    /// <summary>"open" | "dismissed" | "actioned". Set by a ModerationDecision.</summary>
    public string Status { get; set; } = "open";

    public DateTimeOffset? ResolvedAt { get; set; }

    /// <summary>The decision that resolved this report (null while open).</summary>
    public long? DecisionId { get; set; }

    // Navigation properties
    public Channel Channel { get; set; } = null!;
    public ModerationDecision? Decision { get; set; }
}
