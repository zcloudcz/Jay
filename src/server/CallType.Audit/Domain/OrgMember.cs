// ---------------------------------------------------------------------------
// OrgMember.cs — membership of an Account in an Organization
// ---------------------------------------------------------------------------
// Child entity of the Organization aggregate. Construction and removal are
// internal — only Organization is allowed to create/mutate members, so the
// aggregate's invariants (one active Owner, can't strip the last OrgAdmin)
// can never be bypassed by touching an OrgMember directly.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class OrgMember
{
    public Guid OrganizationId { get; private set; }
    public Guid AccountId { get; private set; }
    public OrgRole Role { get; private set; }
    public DateTimeOffset AddedAt { get; private set; }
    public DateTimeOffset? RemovedAt { get; private set; }

    private OrgMember()
    {
    } // EF Core

    internal OrgMember(Guid organizationId, Guid accountId, OrgRole role, DateTimeOffset addedAt)
    {
        OrganizationId = organizationId;
        AccountId = accountId;
        Role = role;
        AddedAt = addedAt;
    }

    internal void Remove(DateTimeOffset now) => RemovedAt = now;

    /// <summary>
    /// In-place role change. Added by E01 — the composite key is
    /// (OrganizationId, AccountId), so a role change can never be modelled as
    /// Remove+AddMember (that would try to insert a second row for the same
    /// key once RemovedAt has already been set on the first).
    /// </summary>
    internal void ChangeRole(OrgRole role) => Role = role;
}
