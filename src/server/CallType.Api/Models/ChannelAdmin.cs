// ---------------------------------------------------------------------------
// ChannelAdmin.cs — Device allowed to publish to / manage a channel
// ---------------------------------------------------------------------------
// Composite PK (ChannelId, DeviceId) = at most one admin row per device per
// channel. Role is a short string for the same reason as GroupMember.Role:
// new roles need no schema migration ("publisher" was added that way).
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ChannelAdmin
{
    public Guid ChannelId { get; set; }
    public Guid DeviceId { get; set; }

    /// <summary>
    /// "admin" (publish, edit profile, delete any post) or "publisher"
    /// (publish and delete OWN posts only, e.g. a newsletter bot). Max 10
    /// chars, defaults to "admin". Owners never have a row here.
    /// </summary>
    public string Role { get; set; } = "admin";

    public DateTimeOffset AddedAt { get; set; }

    // Navigation properties
    public Channel Channel { get; set; } = null!;
}
