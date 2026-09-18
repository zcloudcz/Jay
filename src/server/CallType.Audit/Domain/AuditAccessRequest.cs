// ---------------------------------------------------------------------------
// AuditAccessRequest.cs — "four eyes" access request to the archive (KB5)
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class AuditAccessRequest
{
    public Guid RequestId { get; private set; }
    public Guid OrganizationId { get; private set; }
    public Guid RequesterAccountId { get; private set; }

    /// <summary>Free-form scope description (group/person/period) — E04 defines the exact shape.</summary>
    public string Scope { get; private set; } = string.Empty;

    public string Reason { get; private set; } = string.Empty;
    public DateTimeOffset RequestedAt { get; private set; }
    public Guid? ApproverAccountId { get; private set; }
    public DateTimeOffset? ApprovedAt { get; private set; }
    public DateTimeOffset? RejectedAt { get; private set; }
    public DateTimeOffset? WindowExpiresAt { get; private set; }

    private AuditAccessRequest()
    {
    } // EF Core

    public AuditAccessRequest(Guid requestId, Guid organizationId, Guid requesterAccountId, string scope,
        string reason, DateTimeOffset requestedAt)
    {
        RequestId = requestId;
        OrganizationId = organizationId;
        RequesterAccountId = requesterAccountId;
        Scope = scope;
        Reason = reason;
        RequestedAt = requestedAt;
    }

    /// <summary>Invariant (KB5): the requester can never approve their own request.</summary>
    public void Approve(Guid approverAccountId, DateTimeOffset now, TimeSpan windowDuration)
    {
        if (approverAccountId == RequesterAccountId)
            throw new DomainRuleViolation("self_approval", "The requester cannot approve their own access request.");
        if (ApprovedAt is not null || RejectedAt is not null)
            throw new DomainRuleViolation("already_decided", "Access request was already decided.");

        ApproverAccountId = approverAccountId;
        ApprovedAt = now;
        WindowExpiresAt = now + windowDuration;
    }

    public void Reject(Guid approverAccountId, DateTimeOffset now)
    {
        if (approverAccountId == RequesterAccountId)
            throw new DomainRuleViolation("self_approval", "The requester cannot reject their own access request.");
        if (ApprovedAt is not null || RejectedAt is not null)
            throw new DomainRuleViolation("already_decided", "Access request was already decided.");

        ApproverAccountId = approverAccountId;
        RejectedAt = now;
    }
}
