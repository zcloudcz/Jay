// ---------------------------------------------------------------------------
// AccountMfa.cs — TOTP MFA state for an Account (N03a)
// ---------------------------------------------------------------------------
// One row per Account. The same row is used for both the "pending" secret
// (created by enroll/start, not yet confirmed) and the "active" secret
// (after enroll/confirm) — Enabled distinguishes the two. Re-starting
// enrollment before confirming simply overwrites EncryptedSecret.
//
// EncryptedSecret is AES-256-GCM(nonce || ciphertext || tag) — see
// MfaEncryptionService. This makes a leaked DB dump/backup alone useless to
// mint codes; it does NOT protect against a compromised running API process,
// which holds the decryption key in memory.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class AccountMfa
{
    public Guid AccountId { get; set; }

    /// <summary>nonce (12) || ciphertext || tag (16), AES-256-GCM of the raw TOTP secret.</summary>
    public byte[] EncryptedSecret { get; set; } = [];

    public bool Enabled { get; set; }

    public DateTimeOffset? ConfirmedAt { get; set; }

    /// <summary>Consecutive verify failures since the last success; resets to 0 on success.</summary>
    public int FailedAttempts { get; set; }

    /// <summary>Set after 5 consecutive failures; verify/disable are rejected until this passes.</summary>
    public DateTimeOffset? LockedUntil { get; set; }

    /// <summary>
    /// The last TOTP time-step accepted for this account. A code for a step
    /// at or before this value is rejected as a replay (409 mfa_code_reused) —
    /// simpler than an in-memory used-code cache and survives restarts.
    /// </summary>
    public long? LastAcceptedStep { get; set; }

    public Account? Account { get; set; }

    public List<AccountMfaBackupCode> BackupCodes { get; set; } = [];
}
