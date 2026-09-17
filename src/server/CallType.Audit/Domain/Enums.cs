// ---------------------------------------------------------------------------
// Enums.cs — Org & Audit context enums (plan section 3, KB3)
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

/// <summary>
/// Archive depth policy for an organization (KB3, spec 5.4). Metadata-only is
/// the default and covers everything through E03; Full re-encrypts message
/// content under the organization's OrgAuditKey and lands in E03b, only after
/// the pilot confirms it's actually needed (spec's own validation milestone).
/// </summary>
public enum ArchiveLevel
{
    Metadata,
    Full
}

/// <summary>
/// Roles inside the Org &amp; Audit context. Distinct from
/// <c>GroupMember.Role</c> in the Delivery DB (which only knows
/// "member"/"auditor") — Delivery has no notion of organization governance.
/// </summary>
public enum OrgRole
{
    Owner,
    OrgAdmin,
    AuditorApprover,
    Member
}
