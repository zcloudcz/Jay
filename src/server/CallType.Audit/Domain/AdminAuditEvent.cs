// ---------------------------------------------------------------------------
// AdminAuditEvent.cs — append-only log of Organization-context changes (KB6)
// ---------------------------------------------------------------------------
// Membership, role, enrollment, group and policy changes all become one of
// these. Same hash-chain discipline as AuditRecord (own Sequence/PrevHash/
// Hash per organization) but a SEPARATE chain — an admin event chain proves
// governance history, a record chain proves message archiving; conflating
// them would make either one harder to verify independently.
// DetailsJson must never contain message content — only structured metadata
// about the change itself (who, what changed, previous/new value).
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class AdminAuditEvent
{
    public long Id { get; private set; }
    public Guid OrganizationId { get; private set; }
    public Guid ActorAccountId { get; private set; }

    /// <summary>e.g. "member_added", "member_removed", "policy_changed" — free text, not a fixed enum.</summary>
    public string EventType { get; private set; } = string.Empty;

    public string DetailsJson { get; private set; } = string.Empty;
    public DateTimeOffset OccurredAt { get; private set; }
    public long Sequence { get; private set; }
    public byte[] PrevHash { get; private set; } = [];
    public byte[] Hash { get; private set; } = [];

    private AdminAuditEvent()
    {
    } // EF Core

    public AdminAuditEvent(Guid organizationId, Guid actorAccountId, string eventType, string detailsJson,
        DateTimeOffset occurredAt, long sequence, byte[] prevHash, byte[] hash)
    {
        OrganizationId = organizationId;
        ActorAccountId = actorAccountId;
        EventType = eventType;
        DetailsJson = detailsJson;
        OccurredAt = occurredAt;
        Sequence = sequence;
        PrevHash = prevHash;
        Hash = hash;
    }
}
