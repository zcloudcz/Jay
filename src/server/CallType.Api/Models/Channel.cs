// ---------------------------------------------------------------------------
// Channel.cs — One-way public broadcast channel (WhatsApp Channels style)
// ---------------------------------------------------------------------------
// A channel is NOT a conversation: no Group, no session, no ratchet. Its
// content is public and deliberately NOT end-to-end encrypted — the single
// explicit exception to "the server never sees plaintext" (see
// docs/superpowers/plans/2026-09-16-channels.md). Clients must say so in the UI.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class Channel
{
    public Guid ChannelId { get; set; }

    /// <summary>
    /// Public discovery identifier "CH-XXXX-XXXX" (12 chars), unique. Same
    /// alphabet/format as the device handle (HandleGenerator); the "CH" prefix
    /// lets clients tell a channel QR/link from a contact one.
    /// </summary>
    public string Handle { get; set; } = string.Empty;

    /// <summary>Plaintext channel name, max 64 chars.</summary>
    public string Name { get; set; } = string.Empty;

    /// <summary>Plaintext description, max 512 chars.</summary>
    public string Description { get; set; } = string.Empty;

    /// <summary>
    /// Device that created the channel. Informational only (audit) and therefore
    /// not a foreign key — ownership rights come from OwnerAccountId.
    /// </summary>
    public Guid OwnerDeviceId { get; set; }

    /// <summary>
    /// Registered account that owns the channel. Every device linked to this
    /// account has owner rights, so the channel survives the loss of the
    /// creating device. Only devices with a linked account may create channels.
    /// </summary>
    public Guid OwnerAccountId { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>
    /// Soft delete marker. A deleted channel behaves as 404 for clients but the
    /// row stays so followers can be sent a tombstone and reports keep context.
    /// </summary>
    public DateTimeOffset? DeletedAt { get; set; }

    /// <summary>
    /// Denormalized follower count, updated in the same transaction as
    /// follow/unfollow. Avoids COUNT(*) over ChannelFollowers on every profile
    /// view — the count is the ONLY follower information the API ever exposes.
    /// </summary>
    public int FollowerCount { get; set; }

    /// <summary>
    /// Operator suspension (moderation). Suspended = SuspendedUntil &gt; now;
    /// expiry needs no background job because every check compares with the
    /// clock. Termination is NOT a status here: it is the existing soft delete.
    /// </summary>
    public DateTimeOffset? SuspendedUntil { get; set; }

    public bool IsSuspended(DateTimeOffset now) => SuspendedUntil is { } until && until > now;

    // Navigation properties
    public Account OwnerAccount { get; set; } = null!;
    public List<ChannelAdmin> Admins { get; set; } = [];
    public List<ChannelPost> Posts { get; set; } = [];
    public List<ChannelFollower> Followers { get; set; } = [];
}
