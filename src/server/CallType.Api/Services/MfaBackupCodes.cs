// ---------------------------------------------------------------------------
// MfaBackupCodes.cs — one-time MFA recovery codes (N03a)
// ---------------------------------------------------------------------------
// Same approach as CallType.Audit.Emergency.EmergencyCodes (Crockford base32,
// SHA-256 of a normalized form, only the hash persisted) — duplicated in a
// few lines rather than referenced so CallType.Api's Delivery-side MFA code
// does not depend on CallType.Audit internals for something this small.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using System.Text;

namespace CallType.Api.Services;

public static class MfaBackupCodes
{
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32, no I/L/O/U
    private const int RandomBytes = 10; // 80 bits — plenty for a single-use, rate-limited code

    public const int CodeCount = 10;

    /// <summary>Generates one human-typeable code, e.g. "7K2M-9QRT".</summary>
    public static string Generate()
    {
        var bytes = RandomNumberGenerator.GetBytes(RandomBytes);
        var sb = new StringBuilder();
        int buffer = 0, bitsInBuffer = 0, charsSinceGroup = 0;
        foreach (var b in bytes)
        {
            buffer = (buffer << 8) | b;
            bitsInBuffer += 8;
            while (bitsInBuffer >= 5)
            {
                bitsInBuffer -= 5;
                sb.Append(Alphabet[(buffer >> bitsInBuffer) & 0b11111]);
                if (++charsSinceGroup == 4)
                {
                    sb.Append('-');
                    charsSinceGroup = 0;
                }
            }
        }
        if (bitsInBuffer > 0)
            sb.Append(Alphabet[(buffer << (5 - bitsInBuffer)) & 0b11111]);
        return sb.ToString().TrimEnd('-');
    }

    /// <summary>Hex SHA-256 of the normalized (dashes stripped, upper-cased) code.</summary>
    public static string Hash(string code) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Normalize(code))));

    private static string Normalize(string code) => code.Replace("-", "").Trim().ToUpperInvariant();
}
