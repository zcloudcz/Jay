// ---------------------------------------------------------------------------
// Base32.cs — RFC 4648 base32 encoding, no padding
// ---------------------------------------------------------------------------
// Used only to present the TOTP secret to the user (provisioning URI /
// manual entry) — authenticator apps expect base32, not base64.
// ---------------------------------------------------------------------------

using System.Text;

namespace CallType.Api.Services;

public static class Base32
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string Encode(byte[] data)
    {
        var sb = new StringBuilder();
        int buffer = 0, bitsInBuffer = 0;
        foreach (var b in data)
        {
            buffer = (buffer << 8) | b;
            bitsInBuffer += 8;
            while (bitsInBuffer >= 5)
            {
                bitsInBuffer -= 5;
                sb.Append(Alphabet[(buffer >> bitsInBuffer) & 0b11111]);
            }
        }
        if (bitsInBuffer > 0)
            sb.Append(Alphabet[(buffer << (5 - bitsInBuffer)) & 0b11111]);
        return sb.ToString();
    }

    /// <summary>Inverse of <see cref="Encode"/>. Only used by tests, which need to turn the
    /// provisioning secret the enroll/start endpoint returns back into raw bytes to compute codes.</summary>
    public static byte[] Decode(string base32)
    {
        var bytes = new List<byte>();
        int buffer = 0, bitsInBuffer = 0;
        foreach (var c in base32.TrimEnd('='))
        {
            buffer = (buffer << 5) | Alphabet.IndexOf(char.ToUpperInvariant(c));
            bitsInBuffer += 5;
            if (bitsInBuffer >= 8)
            {
                bitsInBuffer -= 8;
                bytes.Add((byte)((buffer >> bitsInBuffer) & 0xFF));
            }
        }
        return bytes.ToArray();
    }
}
