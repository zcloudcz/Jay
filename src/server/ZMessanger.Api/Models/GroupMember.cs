// ---------------------------------------------------------------------------
// GroupMember.cs — Device membership in a group
// ---------------------------------------------------------------------------
// Membership is per-device (not per-account) because each device holds its
// own key material and must independently receive group messages.
// The composite PK (GroupId, DeviceId) enforces one membership per device
// per group. Role is a simple string ("admin" / "member") rather than an
// enum to keep schema migrations minimal when new roles are added.
// ---------------------------------------------------------------------------

namespace ZMessanger.Api.Models;

public class GroupMember
{
    public Guid GroupId { get; set; }
    public Guid DeviceId { get; set; }

    /// <summary>
    /// Role within the group. Defaults to "member". "admin" can add/remove
    /// members and change group metadata. Kept as a short string (max 10)
    /// for extensibility without schema changes.
    /// </summary>
    public string Role { get; set; } = "member";

    public DateTimeOffset JoinedAt { get; set; }

    // Navigation properties
    public Group Group { get; set; } = null!;
    public Device Device { get; set; } = null!;
}
