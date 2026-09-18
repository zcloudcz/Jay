// ---------------------------------------------------------------------------
// TotpService.cs — hand-rolled RFC 6238 TOTP (HMAC-SHA1, 6 digits, 30s step)
// ---------------------------------------------------------------------------
// No new NuGet dependency — TOTP is a small, well-specified algorithm on top
// of System.Security.Cryptography.HMACSHA1 (RFC 4226 HOTP truncation +
// RFC 6238's "counter = unixTime / period").
//
// Time comes from an injected TimeProvider so tests can control it instead
// of racing the wall clock at 30s step boundaries.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;

namespace CallType.Api.Services;

public class TotpService(TimeProvider clock)
{
    public const int Period = 30;
    public const int Digits = 6;

    /// <summary>The current 30s time-step, per RFC 6238 §4.</summary>
    public long CurrentStep() => clock.GetUtcNow().ToUnixTimeSeconds() / Period;

    /// <summary>
    /// Computes the TOTP code for a given secret and time-step. Static +
    /// digit count parameter so the RFC 6238 Appendix B test vectors (8
    /// digits) and this project's 6-digit codes can both be verified against
    /// the same truncation logic.
    /// </summary>
    public static string ComputeCode(byte[] secret, long step, int digits = Digits)
    {
        // RFC 4226 §5.2: the counter is an 8-byte big-endian integer.
        var counter = BitConverter.GetBytes(step);
        if (BitConverter.IsLittleEndian) Array.Reverse(counter);

        var hash = HMACSHA1.HashData(secret, counter);

        // Dynamic truncation (RFC 4226 §5.3): take a 4-byte window starting
        // at the offset named by the low nibble of the last hash byte, mask
        // off the top bit (keeps the result positive as a signed 31-bit int).
        var offset = hash[^1] & 0x0F;
        var binary = ((hash[offset] & 0x7F) << 24)
                     | ((hash[offset + 1] & 0xFF) << 16)
                     | ((hash[offset + 2] & 0xFF) << 8)
                     | (hash[offset + 3] & 0xFF);

        var otp = binary % (int)Math.Pow(10, digits);
        return otp.ToString().PadLeft(digits, '0');
    }

    /// <summary>
    /// Checks a 6-digit code against steps -1/0/+1 around the current time
    /// (RFC 6238's recommended clock-skew tolerance). Returns the matched
    /// time-step, or null if no nearby step matches — the caller is
    /// responsible for replay rejection (a matched step must still be
    /// compared against the account's last-accepted step).
    /// </summary>
    public long? MatchStep(byte[] secret, string code)
    {
        if (code.Length != Digits || !code.All(char.IsAsciiDigit)) return null;

        var current = CurrentStep();
        for (var delta = -1; delta <= 1; delta++)
        {
            var step = current + delta;
            if (ComputeCode(secret, step) == code) return step;
        }
        return null;
    }
}
