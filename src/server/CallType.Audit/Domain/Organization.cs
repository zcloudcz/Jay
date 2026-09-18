// ---------------------------------------------------------------------------
// Organization.cs — aggregate root for the Org & Audit context (plan §3)
// ---------------------------------------------------------------------------
// Owns its OrgMember list and enforces the two membership invariants named in
// the plan (0.4 / §3): exactly one active Owner, and never remove the last
// active OrgAdmin. E01 owns the actual endpoints; this class only guarantees
// the invariants can't be violated no matter which endpoint calls it.
//
// Ownership transfer is intentionally out of scope for E00 — RemoveMember
// simply refuses to remove an Owner. A future package can add a dedicated
// TransferOwnership method once that flow is designed.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class Organization
{
    public Guid OrganizationId { get; private set; }
    public string Name { get; private set; } = string.Empty;
    public DateTimeOffset CreatedAt { get; private set; }
    public byte[]? ArchivePublicKey { get; set; }
    public int RetentionDays { get; set; }
    public Guid? AuditorDeviceId { get; set; }

    /// <summary>
    /// Current effective archive policy (KB3). Changes to this must be
    /// recorded as an AdminAuditEvent by the caller (E01) — that's what makes
    /// the policy "versioned with effective date" per the plan; this property
    /// only holds the current value.
    /// </summary>
    public ArchiveLevel ArchiveLevel { get; set; } = ArchiveLevel.Metadata;

    /// <summary>
    /// Owner decision 2026-09-18 (plan §8a item 5): the default stays that
    /// only conversations INSIDE a business group are archived — two members
    /// enrolled in the same organization may still talk 1:1, in an anonymous
    /// group, or call each other outside of it. When this is true, the
    /// server additionally refuses those anonymous paths between two actively
    /// enrolled devices of this organization (P1, OrgCommunicationPolicy) —
    /// communication with anyone outside the organization is unaffected.
    /// Mutate only via SetRequireBusinessConversations so a future invariant
    /// has one place to enforce, matching Rename/ArchiveLevel's pattern.
    /// </summary>
    public bool RequireBusinessConversations { get; set; }

    private readonly List<OrgMember> _members = [];

    /// <summary>Read-only view — members are only added/removed through the methods below.</summary>
    public IReadOnlyCollection<OrgMember> Members => _members;

    private Organization()
    {
    } // EF Core

    public static Organization Create(Guid organizationId, string name, Guid ownerAccountId, DateTimeOffset now)
    {
        var org = new Organization
        {
            OrganizationId = organizationId,
            Name = name,
            CreatedAt = now
        };
        org._members.Add(new OrgMember(organizationId, ownerAccountId, OrgRole.Owner, now));
        return org;
    }

    /// <summary>Renames the organization. Added by E01 for PATCH /orgs/{id} — Name has no public setter on purpose elsewhere in the codebase.</summary>
    public void Rename(string name) => Name = name;

    /// <summary>P1: toggles the "audit all communication between our members" policy (PATCH /orgs/{id}).</summary>
    public void SetRequireBusinessConversations(bool value) => RequireBusinessConversations = value;

    public void AddMember(Guid accountId, OrgRole role, DateTimeOffset now)
    {
        if (_members.Any(m => m.AccountId == accountId && m.RemovedAt is null))
            throw new DomainRuleViolation("already_member", "Account is already an active member of this organization.");

        // Invariant: exactly one active Owner. E00 has no ownership-transfer
        // flow, so a second Owner would always be a bug in the caller.
        if (role == OrgRole.Owner && _members.Any(m => m.Role == OrgRole.Owner && m.RemovedAt is null))
            throw new DomainRuleViolation("multiple_owners", "Organization already has an active owner.");

        _members.Add(new OrgMember(OrganizationId, accountId, role, now));
    }

    public void RemoveMember(Guid accountId, DateTimeOffset now)
    {
        var member = _members.FirstOrDefault(m => m.AccountId == accountId && m.RemovedAt is null)
            ?? throw new DomainRuleViolation("member_not_found", "No active member with that account id.");

        if (member.Role == OrgRole.Owner)
            throw new DomainRuleViolation("last_owner", "The owner cannot be removed directly; transfer ownership first.");

        // Invariant: cannot remove the last active OrgAdmin.
        if (member.Role == OrgRole.OrgAdmin)
        {
            var activeAdmins = _members.Count(m => m.Role == OrgRole.OrgAdmin && m.RemovedAt is null);
            if (activeAdmins <= 1)
                throw new DomainRuleViolation("last_admin", "Cannot remove the last org-admin.");
        }

        member.Remove(now);
    }

    /// <summary>
    /// Changes an existing active member's role in place. Added by E01 for
    /// PUT /orgs/{id}/members/{accountId} — cannot be Remove+AddMember
    /// because the composite key (OrganizationId, AccountId) means the row
    /// is never actually deleted (see OrgMember.Remove), so re-adding the
    /// same account would collide on that key. Ownership transfer is out of
    /// scope (same reason as RemoveMember below) — the caller must reject
    /// role == Owner before calling this.
    /// </summary>
    public void ChangeMemberRole(Guid accountId, OrgRole role, DateTimeOffset now)
    {
        var member = _members.FirstOrDefault(m => m.AccountId == accountId && m.RemovedAt is null)
            ?? throw new DomainRuleViolation("member_not_found", "No active member with that account id.");

        if (role == OrgRole.Owner)
            throw new DomainRuleViolation("owner_transfer_unsupported", "Ownership transfer is not supported yet.");
        if (member.Role == OrgRole.Owner)
            throw new DomainRuleViolation("last_owner", "The owner's role cannot be changed directly; transfer ownership first.");

        // Same invariant as RemoveMember: demoting the last active OrgAdmin
        // away from OrgAdmin must be refused just like removing them outright.
        if (member.Role == OrgRole.OrgAdmin && role != OrgRole.OrgAdmin)
        {
            var activeAdmins = _members.Count(m => m.Role == OrgRole.OrgAdmin && m.RemovedAt is null);
            if (activeAdmins <= 1)
                throw new DomainRuleViolation("last_admin", "Cannot demote the last org-admin.");
        }

        member.ChangeRole(role);
    }
}
