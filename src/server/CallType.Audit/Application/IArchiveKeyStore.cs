// ---------------------------------------------------------------------------
// IArchiveKeyStore.cs — holder of an organization's private archive key
// ---------------------------------------------------------------------------
// WHY this interface exists: metadata-only archiving (E00 through E03) never
// needs an OrgAuditKey, but E03b (ArchiveLevel.Full, spec 5.1) will need to
// decrypt re-encrypted content, and E04 (four-eyes access) needs to gate
// that decryption behind an approved AuditAccessRequest. Fixing the contract
// now means both packages can be built against it without knowing the final
// backing store. Target: HSM / Key Vault with threshold approval; the
// interim implementation (dev, and E00-era beta) is a single configuration
// secret — see plan §0.1 KB5 "known limit of step 1".
// ---------------------------------------------------------------------------

namespace CallType.Audit.Application;

public interface IArchiveKeyStore
{
    Task<byte[]> GetPrivateKeyAsync(Guid organizationId, CancellationToken cancellationToken = default);
}
