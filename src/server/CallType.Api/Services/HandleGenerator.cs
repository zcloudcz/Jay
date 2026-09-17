// ---------------------------------------------------------------------------
// HandleGenerator.cs — Random human-readable handles (CT-XXXX-XXXX, CH-XXXX-XXXX)
// ---------------------------------------------------------------------------
// Shared by device handles ("CT") and channel handles ("CH") so both use the
// same alphabet and format — a user who learned to read one can read the other,
// and the client can tell them apart by prefix alone (QR / deep links).
// Uniqueness is NOT guaranteed here; the caller relies on the DB unique index.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;

namespace CallType.Api.Services;

public static class HandleGenerator
{
    public const string DevicePrefix = "CT";
    public const string ChannelPrefix = "CH";

    // Characters used for handle generation. Excludes ambiguous characters
    // (0/O, 1/I/L) to reduce transcription errors when users type handles.
    private const string HandleChars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

    /// <summary>Generates "{prefix}-XXXX-XXXX" from cryptographically random characters.</summary>
    /// <remarks>
    /// With 30 possible chars and 8 random positions, there are ~6.5x10^11
    /// combinations — more than enough for the expected population.
    /// </remarks>
    public static string Generate(string prefix)
    {
        // Use stack allocation for the 8-char random portion to avoid
        // heap pressure on a potentially hot registration path.
        Span<char> part1 = stackalloc char[4];
        Span<char> part2 = stackalloc char[4];

        FillRandom(part1);
        FillRandom(part2);

        return $"{prefix}-{part1}-{part2}";
    }

    private static void FillRandom(Span<char> buffer)
    {
        // RandomNumberGenerator is cryptographically secure and thread-safe,
        // ensuring handles cannot be predicted or enumerated.
        Span<byte> randomBytes = stackalloc byte[buffer.Length];
        RandomNumberGenerator.Fill(randomBytes);

        for (var i = 0; i < buffer.Length; i++)
        {
            // Modulo bias is negligible here: 256 % 30 = 16, giving at most
            // ~6% over-representation for some characters. This is acceptable
            // for an identifier, not a cryptographic key.
            buffer[i] = HandleChars[randomBytes[i] % HandleChars.Length];
        }
    }
}
