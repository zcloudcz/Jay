// ---------------------------------------------------------------------------
// ChannelFollower.cs — A device following a channel
// ---------------------------------------------------------------------------
// PRIVACY: the server needs this link to deliver posts, but it must NEVER be
// returned to channel admins or to other followers — the API exposes only the
// aggregated Channel.FollowerCount. Following is always an explicit user action.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ChannelFollower
{
    public Guid ChannelId { get; set; }
    public Guid DeviceId { get; set; }

    public DateTimeOffset FollowedAt { get; set; }

    /// <summary>
    /// CreatedAt of the newest post this device has seen; drives the unread
    /// badge. Null = nothing seen yet.
    /// </summary>
    public DateTimeOffset? LastSeenPostAt { get; set; }

    // Navigation properties
    public Channel Channel { get; set; } = null!;
}
