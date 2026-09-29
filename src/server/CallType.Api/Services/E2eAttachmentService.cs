// ---------------------------------------------------------------------------
// E2eAttachmentService.cs — encrypted attachment blobs (stream M2) — X0 STUB
// ---------------------------------------------------------------------------
// Stream M2 (package M2-3) implements chunked upload, commit, ranged download,
// delete and quota here — see docs/superpowers/plans/2026-09-29-gap-media.md
// "M2-3" for the exact algorithm. X0 creates the class so Program.cs,
// PrivacyEndpoints and the migration are in place before wave 1.
//
// The only method with a real body is MarkDeviceAttachmentsForDeletionAsync:
// GDPR device deletion (PrivacyEndpoints) calls it, it is a single set-based
// UPDATE, and it is correct on an empty table — so the GDPR path is complete
// from X0 on and M2-4 only adds tests and the export counts.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Services;

/// <summary>Outcome of <see cref="E2eAttachmentService.CreateUploadAsync"/> (M2-3 may extend it).</summary>
public enum CreateUploadResult { Created, InvalidSize, TooLarge, QuotaExceeded }

public class E2eAttachmentService(
    AppDbContext db,
    BlobServiceClient blobs,
    IOptions<AttachmentsOptions> options,
    TimeProvider clock)
{
    /// <summary>
    /// Separate from "backups" and from the PLAINTEXT "channel-media" container
    /// on purpose: nothing unencrypted may ever share a container (and its
    /// lifecycle policy) with E2E ciphertext.
    /// </summary>
    public const string ContainerName = "e2e-attachments";

    internal BlobContainerClient Container => blobs.GetBlobContainerClient(ContainerName);
    internal AttachmentsOptions Options => options.Value;
    // The injected clock (not DateTimeOffset.UtcNow) so M2-3's tests can move
    // time for upload windows, retention and the 24 h quota.
    internal DateTimeOffset Now => clock.GetUtcNow();

    /// <summary>Reserves quota and a CSPRNG blob id. M2-3.</summary>
    public Task<(CreateUploadResult Result, E2eAttachment? Row, string? Scope)> CreateUploadAsync(
        Guid deviceId, long sizeBytes, CancellationToken ct)
        => throw new NotImplementedException("E2eAttachmentService.CreateUploadAsync is implemented by stream M2 (M2-3).");

    /// <summary>Opens a committed, unexpired blob for (ranged) download, else null. M2-3.</summary>
    public Task<Stream?> OpenDownloadAsync(Guid blobId, CancellationToken ct)
        => throw new NotImplementedException("E2eAttachmentService.OpenDownloadAsync is implemented by stream M2 (M2-3).");

    // PutChunkAsync, GetUploadStatusAsync, CommitAsync and DeleteAsync are
    // added by M2-3 together with their result types — nobody outside
    // AttachmentEndpoints calls them, so X0 does not freeze their shapes.

    /// <summary>
    /// GDPR device deletion: marks every not-yet-deleted attachment of the
    /// device as Deleting inside the caller's transaction. The blobs themselves
    /// are removed by E2eAttachmentCleanupService — deleting blobs inside the
    /// transaction would roll back the whole GDPR deletion on a storage hiccup,
    /// while the Deleting state survives a crash and is retried.
    /// Returns the number of rows marked.
    /// </summary>
    public Task<int> MarkDeviceAttachmentsForDeletionAsync(Guid deviceId, CancellationToken ct)
        => db.E2eAttachments
            .Where(a => a.UploaderDeviceId == deviceId
                        && a.Status != E2eAttachmentStatus.Deleted)
            .ExecuteUpdateAsync(s => s.SetProperty(a => a.Status, E2eAttachmentStatus.Deleting), ct);
}
