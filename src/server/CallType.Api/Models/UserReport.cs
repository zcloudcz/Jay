// ---------------------------------------------------------------------------
// UserReport.cs - abuse report against a user (spec 2026-11-14-go-live S6)
// ---------------------------------------------------------------------------
// Private conversations are end-to-end encrypted, so the server cannot look
// at what was said. The REPORTER's app may attach the decrypted text of the
// reported messages (EvidenceJson); the user is told this before sending.
// Read by the operator only (GET /admin/user-reports), never by the reported
// user, and the operator API never returns ReporterDeviceId (same rule as
// ChannelReport). No FKs on purpose: the report is a moderation record that
// outlives both devices; MessageCleanupService removes it after the
// retention period (Moderation:UserReportRetentionDays).
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class UserReport
{
    public long Id { get; set; }

    public Guid ReporterDeviceId { get; set; }

    /// <summary>The reported identity (primary device id).</summary>
    public Guid ReportedPrimaryId { get; set; }

    /// <summary>
    /// Handle of the reported identity at report time. A snapshot because the
    /// reported device may delete itself before the operator looks.
    /// </summary>
    public string ReportedHandle { get; set; } = string.Empty;

    /// <summary>The group the reported behaviour happened in, if any.</summary>
    public Guid? GroupId { get; set; }

    /// <summary>"illegal" | "terms" | "spam" (same set as channel reports).</summary>
    public string Category { get; set; } = "terms";

    public string Reason { get; set; } = string.Empty;

    /// <summary>JSON array of {messageId?, sentAt?, text} supplied by the reporter's app.</summary>
    public string EvidenceJson { get; set; } = "[]";

    public string? ContactEmail { get; set; }

    public bool GoodFaith { get; set; }

    /// <summary>"open" | "dismissed" | "actioned".</summary>
    public string Status { get; set; } = "open";

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? ResolvedAt { get; set; }
}
