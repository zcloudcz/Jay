// ---------------------------------------------------------------------------
// TotpServiceTests.cs — RFC 6238 Appendix B SHA-1 test vectors (N03a)
// ---------------------------------------------------------------------------
// The RFC vectors use the ASCII secret "12345678901234567890" and 8-digit
// codes at fixed Unix times; this project uses 6-digit codes, so both digit
// counts are exercised against the same truncation logic
// (TotpService.ComputeCode takes digits as a parameter for exactly this).
// ---------------------------------------------------------------------------

using System.Text;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Xunit;

namespace CallType.Api.Tests.Services;

public class TotpServiceTests
{
    // RFC 6238 §4: HMAC-SHA1 secret is the ASCII string repeated to 20 bytes.
    private static readonly byte[] Sha1Secret = Encoding.ASCII.GetBytes("12345678901234567890");

    [Theory]
    // (Unix time, expected 8-digit code) — RFC 6238 Appendix B, SHA1 column.
    [InlineData(59L, "94287082")]
    [InlineData(1111111109L, "07081804")]
    [InlineData(1111111111L, "14050471")]
    [InlineData(1234567890L, "89005924")]
    [InlineData(2000000000L, "69279037")]
    public void ComputeCode_MatchesRfc6238AppendixB_8Digits(long unixTime, string expectedCode)
    {
        var step = unixTime / TotpService.Period;
        TotpService.ComputeCode(Sha1Secret, step, digits: 8).Should().Be(expectedCode);
    }

    [Fact]
    public void ComputeCode_6Digits_IsThe8DigitCodesLast6Digits()
    {
        // Truncating a correct 8-digit code to its last 6 digits is exactly
        // what "digits=6" does (both take the same modulo of the same 31-bit
        // dynamic-truncation value) — a cheap independent check that the
        // 6-digit path uses the same underlying computation as the RFC
        // vectors above, not a separate (and separately-buggy) code path.
        var step = 59L / TotpService.Period;
        var eightDigit = TotpService.ComputeCode(Sha1Secret, step, digits: 8);
        var sixDigit = TotpService.ComputeCode(Sha1Secret, step, digits: 6);
        sixDigit.Should().Be(eightDigit[^6..]);
    }

    [Fact]
    public void MatchStep_AcceptsCurrentAndAdjacentSteps_RejectsTwoStepsAway()
    {
        var secret = "any-20-byte-ish-secret!!"u8.ToArray();
        var clock = new FakeTimeProvider(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var service = new TotpService(clock);
        var currentStep = service.CurrentStep();

        var codeMinusOne = TotpService.ComputeCode(secret, currentStep - 1);
        var codePlusOne = TotpService.ComputeCode(secret, currentStep + 1);
        var codeTwoAway = TotpService.ComputeCode(secret, currentStep + 2);

        service.MatchStep(secret, codeMinusOne).Should().Be(currentStep - 1);
        service.MatchStep(secret, codePlusOne).Should().Be(currentStep + 1);
        service.MatchStep(secret, codeTwoAway).Should().BeNull();
    }

    [Fact]
    public void MatchStep_RejectsMalformedCode()
    {
        var secret = "secret"u8.ToArray();
        var service = new TotpService(new FakeTimeProvider(DateTimeOffset.UtcNow));
        service.MatchStep(secret, "12345").Should().BeNull(); // too short
        service.MatchStep(secret, "abcdef").Should().BeNull(); // not digits
    }
}
