// ---------------------------------------------------------------------------
// OrgEnrollmentTests.cs — invite redemption invariant (plan §3, E00)
// ---------------------------------------------------------------------------

using CallType.Audit.Domain;
using FluentAssertions;

namespace CallType.Api.Tests.Audit;

public class OrgEnrollmentTests
{
    private static readonly DateTimeOffset IssuedAt = new(2026, 9, 17, 12, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset ExpiresAt = IssuedAt.AddDays(7);

    private static OrgInvite MakeInvite() =>
        new(Guid.NewGuid(), Guid.NewGuid(), "INVITE-CODE", Guid.NewGuid(), IssuedAt, ExpiresAt);

    [Fact]
    public void Enroll_succeeds_with_a_valid_unexpired_unused_invite()
    {
        var invite = MakeInvite();
        var deviceId = Guid.NewGuid();
        var accountId = Guid.NewGuid();

        var enrollment = OrgEnrollment.Enroll(invite, deviceId, accountId, IssuedAt.AddHours(1));

        enrollment.OrganizationId.Should().Be(invite.OrganizationId);
        enrollment.DeviceId.Should().Be(deviceId);
        invite.UsedAt.Should().Be(IssuedAt.AddHours(1));
    }

    [Fact]
    public void Enroll_rejects_an_expired_invite()
    {
        var invite = MakeInvite();

        var act = () => OrgEnrollment.Enroll(invite, Guid.NewGuid(), Guid.NewGuid(), ExpiresAt.AddSeconds(1));

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("invite_invalid");
    }

    [Fact]
    public void Enroll_rejects_an_already_used_invite()
    {
        var invite = MakeInvite();
        OrgEnrollment.Enroll(invite, Guid.NewGuid(), Guid.NewGuid(), IssuedAt.AddHours(1));

        var act = () => OrgEnrollment.Enroll(invite, Guid.NewGuid(), Guid.NewGuid(), IssuedAt.AddHours(2));

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("invite_invalid");
    }
}
