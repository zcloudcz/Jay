// ---------------------------------------------------------------------------
// Group.cs — Encrypted group metadata
// ---------------------------------------------------------------------------
// Groups are a server-side construct for fan-out: when a member sends a
// message, the server knows which devices to relay it to. The group name
// is encrypted client-side (NameEncrypted) so the server never learns it.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

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

    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>
    /// Null for anonymous groups (the vast majority — never changes). Set only
    /// for a business group owned by an organization (plan §1); Delivery knows
    /// organizations only by this id — no FK into the separate Audit database
    /// (KB3: the two databases stay independent, different credentials).
    /// </summary>
    public Guid? OrganizationId { get; set; }

    /// <summary>
    /// True for the one distinguished business group per organization used as
    /// its emergency channel (E07, spec 2.3/2.6) — lets EmergencyEndpoints find
    /// "the" emergency group without guessing among an org's other business
    /// groups. Always false for anonymous groups and for ordinary business
    /// groups created via POST /groups/business.
    /// </summary>
    public bool IsEmergencyChannel { get; set; }

    /// <summary>
    /// Whether and how bots in this group may talk to each other
    /// (bot conversations design D1-D4). Plaintext metadata on purpose, like
    /// membership and roles: the bots enforce the rules client-side and must
    /// be able to read them; message content stays E2E. Stored as columns of
    /// the Groups table (owned type), never null.
    /// </summary>
    public GroupBotTalk BotTalk { get; set; } = new();

    // Navigation property
    public List<GroupMember> Members { get; set; } = [];
}
