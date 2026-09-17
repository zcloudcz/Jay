// ---------------------------------------------------------------------------
// DailyRoot.cs / OrgDailyProof.cs — daily Merkle root + per-org proof (KB4)
// ---------------------------------------------------------------------------
// One DailyRoot per calendar day, shared across all organizations (a single
// tree over that day's hashes); each organization gets its own Merkle proof
// (OrgDailyProof) that its branch is included, without needing DB access to
// verify it later. TimestampToken/TsaName/ExpiresAt are null until a TSA
// (see Application.ITimestampAuthority) has stamped the root — until then
// the chain only proves internal integrity, not third-party-provable time.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class DailyRoot
{
    public DateOnly Day { get; private set; }
    public byte[] RootHash { get; private set; } = [];
    public byte[]? TimestampToken { get; private set; }
    public string? TsaName { get; private set; }
    public DateTimeOffset? ExpiresAt { get; private set; }
    public DateTimeOffset CreatedAt { get; private set; }

    private DailyRoot()
    {
    } // EF Core

    public DailyRoot(DateOnly day, byte[] rootHash, byte[]? timestampToken, string? tsaName,
        DateTimeOffset? expiresAt, DateTimeOffset createdAt)
    {
        Day = day;
        RootHash = rootHash;
        TimestampToken = timestampToken;
        TsaName = tsaName;
        ExpiresAt = expiresAt;
        CreatedAt = createdAt;
    }
}

public class OrgDailyProof
{
    public long Id { get; private set; }
    public DateOnly Day { get; private set; }
    public Guid OrganizationId { get; private set; }

    /// <summary>Serialized Merkle proof (sibling hashes + left/right flags) — E03 owns the wire format.</summary>
    public byte[] ProofPath { get; private set; } = [];

    public DateTimeOffset CreatedAt { get; private set; }

    private OrgDailyProof()
    {
    } // EF Core

    public OrgDailyProof(DateOnly day, Guid organizationId, byte[] proofPath, DateTimeOffset createdAt)
    {
        Day = day;
        OrganizationId = organizationId;
        ProofPath = proofPath;
        CreatedAt = createdAt;
    }
}
