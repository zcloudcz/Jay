// ---------------------------------------------------------------------------
// EmergencyCodes.cs — one-time offline-enrollment code generation + hashing
// ---------------------------------------------------------------------------
// Codes must be usable when M365/SSO/e-mail (and therefore easy copy/paste
// via those channels) may be down — spec 2.3 calls for a printable, typeable
// code. 128 bits of randomness, Crockford base32 (no I/L/O/U, avoids
// look-alike typos), grouped in blocks of 5 for human transcription.
//
// Only SHA-256 of the code is ever persisted (never the plaintext) — codes
// carry 128 bits of entropy so a fast hash is fine; this is not a
// human-memorable password needing Argon2-style stretching.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using System.Text;

namespace CallType.Audit.Emergency;

public static class EmergencyCodes
{
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32
    private const int RandomBytes = 16; // 128 bits

    /// <summary>Generates one human-typeable code, e.g. "7K2M-9QRT-XV34-...".</summary>
    public static string Generate()
    {
        var bytes = RandomNumberGenerator.GetBytes(RandomBytes);
        var sb = new StringBuilder();
        // 5-bit groups packed from the byte stream; the last partial group is
        // padded with zero bits, which is fine — this is an opaque token, not
        // a value anyone decodes back to bytes.
        int buffer = 0, bitsInBuffer = 0, charsSinceGroup = 0;
        foreach (var b in bytes)
        {
            buffer = (buffer << 8) | b;
            bitsInBuffer += 8;
            while (bitsInBuffer >= 5)
            {
                bitsInBuffer -= 5;
                var index = (buffer >> bitsInBuffer) & 0b11111;
                sb.Append(Alphabet[index]);
                if (++charsSinceGroup == 4 && sb.Length < 30)
                {
                    sb.Append('-');
                    charsSinceGroup = 0;
                }
            }
        }
        if (bitsInBuffer > 0)
        {
            var index = (buffer << (5 - bitsInBuffer)) & 0b11111;
            sb.Append(Alphabet[index]);
        }
        return sb.ToString().TrimEnd('-');
    }

    /// <summary>Hex-encoded SHA-256 of the code, normalized (upper-case, dashes stripped) so a
    /// user retyping with/without dashes or in lower case still matches.</summary>
    public static string Hash(string code)
    {
        var normalized = Normalize(code);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(hash);
    }

    private static string Normalize(string code) =>
        code.Replace("-", "").Trim().ToUpperInvariant();
}
