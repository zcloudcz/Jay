// ---------------------------------------------------------------------------
// MfaAuthHelperTests.cs — pure-claims unit tests for the N03b integration seam
// ---------------------------------------------------------------------------
// Deliberately NOT an HTTP test: RequireStepUp takes a ClaimsPrincipal and
// does no DB round trip, so it's tested directly with hand-built principals
// instead of standing up a test-only endpoint (per the package brief).
// ---------------------------------------------------------------------------

using System.Security.Claims;
using CallType.Api.Endpoints;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Xunit;

namespace CallType.Api.Tests.Endpoints;

public class MfaAuthHelperTests
{
    private static ClaimsPrincipal StepUpPrincipal(Guid accountId, DateTimeOffset mfaAt) =>
        new(new ClaimsIdentity(
        [
            new Claim("amr", "totp"),
            new Claim("mfa_acc", accountId.ToString()),
            new Claim("mfa_at", mfaAt.ToUnixTimeSeconds().ToString())
        ], "Bearer"));

    [Fact]
    public void RequireStepUp_NullWhenClaimsMatchAndRecent()
    {
        var accountId = Guid.NewGuid();
        var clock = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var principal = StepUpPrincipal(accountId, clock.GetUtcNow());

        MfaAuthHelper.RequireStepUp(principal, accountId, clock).Should().BeNull();
    }

    [Fact]
    public void RequireStepUp_ForbiddenWhenNoAmrClaim()
    {
        var accountId = Guid.NewGuid();
        var principal = new ClaimsPrincipal(new ClaimsIdentity([new Claim("sub", Guid.NewGuid().ToString())], "Bearer"));

        var result = MfaAuthHelper.RequireStepUp(principal, accountId, new FakeTimeProvider(DateTimeOffset.UtcNow));

        result.Should().NotBeNull();
    }

    [Fact]
    public void RequireStepUp_ForbiddenWhenClaimIsForADifferentAccount()
    {
        var clock = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var principal = StepUpPrincipal(Guid.NewGuid(), clock.GetUtcNow());

        MfaAuthHelper.RequireStepUp(principal, Guid.NewGuid(), clock).Should().NotBeNull();
    }

    [Fact]
    public void RequireStepUp_ForbiddenOnceTheWindowExpires()
    {
        var accountId = Guid.NewGuid();
        var mfaAt = DateTimeOffset.UtcNow;
        var principal = StepUpPrincipal(accountId, mfaAt);
        var clock = new FakeTimeProvider(mfaAt.AddMinutes(MfaAuthHelper.DefaultWindowMinutes + 1));

        MfaAuthHelper.RequireStepUp(principal, accountId, clock).Should().NotBeNull();
    }
}
