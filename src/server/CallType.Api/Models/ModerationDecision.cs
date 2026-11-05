// ---------------------------------------------------------------------------
// ModerationDecision.cs - One operator decision about a channel or a post
// ---------------------------------------------------------------------------
// Append-only audit row AND the statement of reasons shown to the channel's
// owner/admins (DSA Art. 17). Nothing in the API updates or deletes a row;
// a decision is "undone" only by a newer one (e.g. restore_channel after
// suspend_channel), so the history stays complete.
//
// OperatorAccountId is deliberately NOT a foreign key: the audit trail must
// outlive the operator's account (and it is an operator record, not personal
// data of the channel's users, so it is not part of any data export).
// Contract: docs/superpowers/specs/2026-11-05-channel-moderation-contract.md.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ModerationDecision
{
    public long Id { get; set; }

    public Guid ChannelId { get; set; }

    /// <summary>Post the decision is about, or null for a channel-level decision. No FK: survives retention.</summary>
    public Guid? PostId { get; set; }

    /// <summary>dismiss | remove_post | suspend_channel | terminate_channel | restore_channel</summary>
    public string Action { get; set; } = string.Empty;

    /// <summary>"terms" | "illegal" | null (dismiss / restore take no ground).</summary>
    public string? Ground { get; set; }

    /// <summary>Rule id K1..K10 of docs/legal/pravidla-kanalu.md when Ground = terms.</summary>
    public string? Rule { get; set; }

    /// <summary>Legal provision when Ground = illegal (1..300 chars).</summary>
    public string? LegalGround { get; set; }

    /// <summary>Explanation for the owner (1..2000 chars), part of the statement of reasons.</summary>
    public string Explanation { get; set; } = string.Empty;

    public DateTimeOffset? SuspendedUntil { get; set; }

    public Guid OperatorAccountId { get; set; }

    /// <summary>How many reports this decision resolved (0 = own-initiative decision).</summary>
    public int ReportCount { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    // Navigation properties
    public Channel Channel { get; set; } = null!;
}
