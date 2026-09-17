// ---------------------------------------------------------------------------
// OrgEnrollment.cs — a device enrolled into an organization via an invite
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class OrgEnrollment
{
    public Guid OrganizationId { get; private set; }
    public Guid DeviceId { get; private set; }
    public Guid AccountId { get; private set; }
    public DateTimeOffset EnrolledAt { get; private set; }
    public DateTimeOffset? RevokedAt { get; set; }

    private OrgEnrollment()
    {
    } // EF Core

    /// <summary>
    /// The only way to create an enrollment — redeems the invite as part of
    /// the same operation so an enrollment can never exist without a validly
    /// consumed invite (the invariant lives on OrgInvite.Redeem).
    /// </summary>
    public static OrgEnrollment Enroll(OrgInvite invite, Guid deviceId, Guid accountId, DateTimeOffset now)
    {
        invite.Redeem(now);
        return new OrgEnrollment
        {
            OrganizationId = invite.OrganizationId,
            DeviceId = deviceId,
            AccountId = accountId,
            EnrolledAt = now
        };
    }
}
