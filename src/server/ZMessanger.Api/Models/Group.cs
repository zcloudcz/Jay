// ---------------------------------------------------------------------------
// Group.cs — Encrypted group metadata
// ---------------------------------------------------------------------------
// Groups are a server-side construct for fan-out: when a member sends a
// message, the server knows which devices to relay it to. The group name
// is encrypted client-side (NameEncrypted) so the server never learns it.
// ---------------------------------------------------------------------------

namespace ZMessanger.Api.Models;

public class Group
{
    public Guid GroupId { get; set; }

    /// <summary>
    /// Group display name encrypted with the group's shared symmetric key.
    /// Null for unnamed groups (e.g. ad-hoc multi-device chats).
    /// The server stores this blob for convenience but cannot decrypt it.
    /// </summary>
    public byte[]? NameEncrypted { get; set; }

    /// <summary>
    /// DeviceId of the device that created the group. Used for audit and
    /// default admin assignment.
    /// </summary>
    public Guid CreatedBy { get; set; }

    public DateTime CreatedAt { get; set; }

    // Navigation property
    public List<GroupMember> Members { get; set; } = [];
}
