// ---------------------------------------------------------------------------
// Account.cs — User account (identity + authentication)
// ---------------------------------------------------------------------------
// An account owns one or more devices via the AccountDevice join table.
// Authentication uses Argon2-hashed keys — the server never stores raw
// secrets. Email is the only PII the server holds; it is used solely for
// account recovery flows and is never shared with other users.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class Account
{
    public Guid AccountId { get; set; }

    /// <summary>
    /// Unique email address. Used for account recovery only — never exposed
    /// to other users. Max 255 chars per RFC 5321.
    /// </summary>
    public string Email { get; set; } = string.Empty;

    /// <summary>
    /// Argon2id hash of the authentication key. The raw key is never stored;
    /// clients prove possession during login by providing the key which the
    /// server hashes and compares.
    /// </summary>
    public byte[] AuthKeyHash { get; set; } = [];

    public DateTimeOffset CreatedAt { get; set; }

    // Navigation properties
    public List<AccountDevice> AccountDevices { get; set; } = [];
    public List<Backup> Backups { get; set; } = [];
}
