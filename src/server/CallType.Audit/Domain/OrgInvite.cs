// ---------------------------------------------------------------------------
// OrgInvite.cs — single-use enrollment code (plan §3)
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class OrgInvite
{
    public Guid InviteId { get; private set; }
    public Guid OrganizationId { get; private set; }
    public string Code { get; private set; } = string.Empty;
    public Guid IssuedByAccountId { get; private set; }
    public DateTimeOffset IssuedAt { get; private set; }
    public DateTimeOffset ExpiresAt { get; private set; }
    public DateTimeOffset? UsedAt { get; private set; }

    private OrgInvite()
    {
    } // EF Core

    public OrgInvite(Guid inviteId, Guid organizationId, string code, Guid issuedByAccountId,
        DateTimeOffset issuedAt, DateTimeOffset expiresAt)
    {
        InviteId = inviteId;
        OrganizationId = organizationId;
        Code = code;
        IssuedByAccountId = issuedByAccountId;
        IssuedAt = issuedAt;
        ExpiresAt = expiresAt;
    }

    /// <summary>
    /// Invariant: enrollment only happens with a valid, unexpired, unused
    /// invite. Called from <see cref="OrgEnrollment.Enroll"/> so the two can
    /// never drift apart (an enrollment can't exist without a validly
    /// redeemed invite).
    /// </summary>
    internal void Redeem(DateTimeOffset now)
    {
        if (UsedAt is not null)
            throw new DomainRuleViolation("invite_invalid", "Invite was already used.");
        if (now >= ExpiresAt)
            throw new DomainRuleViolation("invite_invalid", "Invite has expired.");

        UsedAt = now;
    }
}
