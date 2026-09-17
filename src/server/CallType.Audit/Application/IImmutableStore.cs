// ---------------------------------------------------------------------------
// IImmutableStore.cs — optional WORM export target for daily roots (KB4)
// ---------------------------------------------------------------------------
// WHY this interface exists: spec 6.1 forbids a hard dependency on Azure (or
// any single cloud vendor) in the core product. Exporting the daily Merkle
// root to immutable storage (Azure Immutable Blob, S3 Object Lock, a local
// append-only file) is valuable but optional — the domain and the KB4 job
// must keep working with no implementation registered at all.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Application;

public interface IImmutableStore
{
    Task WriteAsync(string path, byte[] content, CancellationToken cancellationToken = default);
}
