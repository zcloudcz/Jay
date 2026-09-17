// ---------------------------------------------------------------------------
// HashChain.cs — canonical serialization + chained hash (KB3/KB6)
// ---------------------------------------------------------------------------
// Shared by AuditRecord (E03) and AdminAuditEvent (E01): both need
// Hash = SHA-256(PrevHash ‖ canonical(record)) so an offline verifier can
// walk the chain and detect any row a superuser edited after the fact
// (rewriting one row breaks every Hash after it, because each Hash folds in
// the previous one).
//
// Canonicalize joins field values with the ASCII Unit Separator (0x1F) — a
// byte that never appears in normal text — so ("ab","c") and ("a","bc")
// never collide the way naive concatenation or comma-joining would.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using System.Text;

namespace CallType.Audit.Application;

public static class HashChain
{
    public const int HashLength = 32; // SHA-256 output size.

    /// <summary>The first record in every chain has this as its PrevHash — 32 zero bytes, not a hash of anything.</summary>
    public static byte[] Genesis => new byte[HashLength];

    private const char FieldSeparator = ''; // ASCII Unit Separator.

    /// <summary>
    /// Joins field values in the given (caller-chosen) order into the exact
    /// string that gets hashed. Callers must always serialize a given record
    /// type's fields in the same order — the order itself is part of what
    /// makes the chain reproducible.
    /// </summary>
    public static string Canonicalize(IEnumerable<string?> orderedFieldValues) =>
        string.Join(FieldSeparator, orderedFieldValues.Select(v => v ?? string.Empty));

    /// <summary>Computes SHA-256(prevHash ‖ UTF8(canonicalRecord)).</summary>
    public static byte[] ComputeHash(byte[] prevHash, string canonicalRecord)
    {
        ArgumentNullException.ThrowIfNull(prevHash);
        ArgumentNullException.ThrowIfNull(canonicalRecord);

        var canonicalBytes = Encoding.UTF8.GetBytes(canonicalRecord);
        var input = new byte[prevHash.Length + canonicalBytes.Length];
        Buffer.BlockCopy(prevHash, 0, input, 0, prevHash.Length);
        Buffer.BlockCopy(canonicalBytes, 0, input, prevHash.Length, canonicalBytes.Length);

        return SHA256.HashData(input);
    }
}
