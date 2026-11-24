// ---------------------------------------------------------------------------
// UserBlock.cs - one identity blocks another (spec 2026-11-14-go-live S1)
// ---------------------------------------------------------------------------
// Both sides are IDENTITIES (primary device ids): conversations are keyed by
// identity, so a blocked person must not get through from a companion. The
// hub drops the blocked identity's copies to every device of the blocker
// (MessengerHub.Blocks.cs). Both FKs cascade at DB level, because
// PrivacyEndpoints deletes devices with raw SQL.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class UserBlock
{
    /// <summary>Most identities one identity may block (S2, 400 block_limit).</summary>
    public const int MaxPerIdentity = 1000;

    public long Id { get; set; }

    /// <summary>The identity that blocks (primary device id).</summary>
    public Guid BlockerPrimaryId { get; set; }

    /// <summary>The identity that is blocked (primary device id).</summary>
    public Guid BlockedPrimaryId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
}
