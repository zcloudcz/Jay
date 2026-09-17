// ---------------------------------------------------------------------------
// ChannelAdmin.cs — Device allowed to publish to / manage a channel
// ---------------------------------------------------------------------------
// Composite PK (ChannelId, DeviceId) = at most one admin row per device per
// channel. Role is a short string ("owner" / "admin") for the same reason as
// GroupMember.Role: new roles need no schema migration.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ChannelAdmin
{
    public Guid ChannelId { get; set; }
    public Guid DeviceId { get; set; }

    /// <summary>"owner" or "admin" (max 10 chars). Defaults to "admin".</summary>
    public string Role { get; set; } = "admin";

    public DateTimeOffset AddedAt { get; set; }

    // Navigation properties
    public Channel Channel { get; set; } = null!;
}
