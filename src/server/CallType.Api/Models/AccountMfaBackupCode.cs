// ---------------------------------------------------------------------------
// AccountMfaBackupCode.cs — single-use MFA recovery codes (N03a)
// ---------------------------------------------------------------------------
// 10 codes are generated at enroll/confirm and on regenerate, returned once
// in plaintext, and only their hash is ever persisted — same approach as
// CallType.Audit.Emergency.EmergencyCodes (SHA-256, normalized), duplicated
// here rather than referenced so CallType.Api's Delivery-side MFA code does
// not take on a dependency on CallType.Audit internals for something this
// small.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class AccountMfaBackupCode
{
    public long Id { get; set; }

    public Guid AccountId { get; set; }

    public string CodeHash { get; set; } = string.Empty;

    /// <summary>Set the first (and only) time this code is redeemed — never unset.</summary>
    public DateTimeOffset? UsedAt { get; set; }

    public AccountMfa? AccountMfa { get; set; }
}
