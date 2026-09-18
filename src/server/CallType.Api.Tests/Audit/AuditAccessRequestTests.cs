// ---------------------------------------------------------------------------
// AuditAccessRequestTests.cs — four-eyes invariant (KB5, plan §3, E00)
// ---------------------------------------------------------------------------

using CallType.Audit.Domain;
using FluentAssertions;

namespace CallType.Api.Tests.Audit;

public class AuditAccessRequestTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 17, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Approve_rejects_the_requester_approving_their_own_request()
    {
        var requesterId = Guid.NewGuid();
        var request = new AuditAccessRequest(Guid.NewGuid(), Guid.NewGuid(), requesterId, "group:x", "compliance check", Now);

        var act = () => request.Approve(requesterId, Now, TimeSpan.FromHours(1));

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("self_approval");
    }

    [Fact]
    public void Reject_rejects_the_requester_rejecting_their_own_request()
    {
        var requesterId = Guid.NewGuid();
        var request = new AuditAccessRequest(Guid.NewGuid(), Guid.NewGuid(), requesterId, "group:x", "compliance check", Now);

        var act = () => request.Reject(requesterId, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("self_approval");
    }

    [Fact]
    public void Approve_by_a_different_account_opens_a_time_bounded_window()
    {
        var request = new AuditAccessRequest(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), "group:x", "compliance check", Now);
        var approverId = Guid.NewGuid();

        request.Approve(approverId, Now, TimeSpan.FromHours(2));

        request.ApproverAccountId.Should().Be(approverId);
        request.WindowExpiresAt.Should().Be(Now.AddHours(2));
    }

    [Fact]
    public void Approve_rejects_a_request_that_was_already_decided()
    {
        var request = new AuditAccessRequest(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), "group:x", "compliance check", Now);
        request.Approve(Guid.NewGuid(), Now, TimeSpan.FromHours(1));

        var act = () => request.Approve(Guid.NewGuid(), Now, TimeSpan.FromHours(1));

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("already_decided");
    }
}
