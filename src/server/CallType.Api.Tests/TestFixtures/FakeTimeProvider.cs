// ---------------------------------------------------------------------------
// FakeTimeProvider.cs — settable TimeProvider for MFA tests (N03a)
// ---------------------------------------------------------------------------
// A handful of MFA tests need to control "now" precisely (TOTP time-steps,
// lockout expiry, step-up token windows) without racing the wall clock at
// 30s step boundaries. No new package — TimeProvider is a small abstract
// class, a settable override is a few lines.
// ---------------------------------------------------------------------------

namespace CallType.Api.Tests.TestFixtures;

public class FakeTimeProvider(DateTimeOffset start) : TimeProvider
{
    private DateTimeOffset _now = start;

    public override DateTimeOffset GetUtcNow() => _now;

    public void Set(DateTimeOffset now) => _now = now;

    public void Advance(TimeSpan span) => _now += span;
}
