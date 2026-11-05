// ---------------------------------------------------------------------------
// ModerationOptions.cs - Operator (channel moderation) configuration
// ---------------------------------------------------------------------------
// Bound from the "Moderation" section (Moderation__OperatorAccountIds__0=...
// as env vars). The allowlist is configuration, not a DB role, on purpose:
// there is one operator, granting the role needs a deploy (an audited change)
// and no API can escalate an account to operator.
// Contract: docs/superpowers/specs/2026-11-05-channel-moderation-contract.md.
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class ModerationOptions
{
    public const string SectionName = "Moderation";

    /// <summary>
    /// Accounts allowed to open an operator session. Empty (default) = the
    /// whole /admin API answers 404, so a deployment without an operator does
    /// not even reveal that the surface exists.
    /// </summary>
    public List<Guid> OperatorAccountIds { get; set; } = [];

    /// <summary>Lifetime of an operator token in minutes (no refresh: TOTP again). 30 default.</summary>
    public int SessionMinutes { get; set; } = 30;
}
