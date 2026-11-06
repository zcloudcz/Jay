// ---------------------------------------------------------------------------
// ModerationOptions.cs - Operator (channel moderation) configuration
// ---------------------------------------------------------------------------
// Bound from the "Moderation" section (Moderation__OperatorAccountIds__0=...
// or Moderation__OperatorHandles__0=CT-XXXX-XXXX as env vars). The allowlist is configuration, not a DB role, on purpose:
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

    /// <summary>
    /// Device handles (CT-XXXX-XXXX, case-insensitive) whose linked account is
    /// an operator. Exists because the owner knows his handle, not his account
    /// GUID. Matched against the devices linked to the account at the time of
    /// each check, so unlinking the device revokes the role.
    /// </summary>
    public List<string> OperatorHandles { get; set; } = [];

    /// <summary>OperatorHandles trimmed and upper-cased like GET /devices/by-handle; blanks dropped.</summary>
    public List<string> NormalizedOperatorHandles() =>
        OperatorHandles.Where(h => !string.IsNullOrWhiteSpace(h))
            .Select(h => h.Trim().ToUpperInvariant()).Distinct().ToList();

    /// <summary>True when either allowlist names someone; otherwise /admin answers 404.</summary>
    public bool HasOperators => OperatorAccountIds.Count > 0 || NormalizedOperatorHandles().Count > 0;

    /// <summary>Lifetime of an operator token in minutes (no refresh: TOTP again). 30 default.</summary>
    public int SessionMinutes { get; set; } = 30;
}
