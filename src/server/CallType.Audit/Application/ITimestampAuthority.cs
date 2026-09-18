// ---------------------------------------------------------------------------
// ITimestampAuthority.cs — RFC 3161 time-stamping abstraction (KB4)
// ---------------------------------------------------------------------------
// WHY this interface exists: a hash chain alone doesn't prove WHEN a day's
// Merkle root existed — whoever controls the DB could regenerate the whole
// chain after the fact. A qualified timestamp from an independent authority
// closes that gap. Self-hosted rule (spec 6.1) means production points this
// at a real eIDAS-qualified TSA (PostSignum/I.CA) over the network, never a
// hosted SaaS the product depends on to function; dev/test use a
// deterministic fake (see E03) so tests don't need network access.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Application;

public interface ITimestampAuthority
{
    Task<TimestampToken> StampAsync(byte[] rootHash, CancellationToken cancellationToken = default);
}

/// <summary>Result of stamping a root hash — see DailyRoot for how it's persisted.</summary>
public sealed record TimestampToken(byte[] Token, string TsaName, DateTimeOffset ExpiresAt);
