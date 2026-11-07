// ---------------------------------------------------------------------------
// MediaBlobStore.cs - Blob naming and deletion shared by the media code paths
// ---------------------------------------------------------------------------
// Used by MediaEndpoints, MediaCleanupService and PrivacyEndpoints so the
// container name, the block id format and the "release uncommitted blocks"
// trick live in exactly one place.
// ---------------------------------------------------------------------------

using System.Text;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;

namespace CallType.Api.Services;

public static class MediaBlobStore
{
    /// <summary>Container for encrypted media; blob name = media id (no other metadata).</summary>
    public const string ContainerName = "media";

    // Azure requires every block id of one blob to have the same length, so the
    // index is zero-padded to a fixed width. 6 digits cover 5 GiB / 1 MiB chunks.
    private const string BlockIdFormat = "D6";

    public static BlockBlobClient GetBlob(BlobServiceClient service, Guid mediaId) =>
        service.GetBlobContainerClient(ContainerName).GetBlockBlobClient(mediaId.ToString());

    /// <summary>base64(ascii(index.ToString("D6"))): the fixed block id of chunk <paramref name="index"/>.</summary>
    public static string BlockId(int index) =>
        Convert.ToBase64String(Encoding.ASCII.GetBytes(index.ToString(BlockIdFormat)));

    /// <summary>Inverse of <see cref="BlockId"/>; null for a block id this code never wrote.</summary>
    public static int? ParseBlockId(string blockId)
    {
        try
        {
            var text = Encoding.ASCII.GetString(Convert.FromBase64String(blockId));
            return text.Length == 6 && int.TryParse(text, System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture, out var index) ? index : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>
    /// Received chunks: index -> staged length, from the blob's UNCOMMITTED
    /// block list. A blob nobody staged anything to yet answers 404, which
    /// simply means "nothing received".
    /// </summary>
    public static async Task<Dictionary<int, long>> GetStagedChunksAsync(BlockBlobClient blob, CancellationToken ct)
    {
        var result = new Dictionary<int, long>();
        BlockList list;
        try
        {
            list = (await blob.GetBlockListAsync(BlockListTypes.Uncommitted, cancellationToken: ct)).Value;
        }
        catch (RequestFailedException e) when (e.Status == 404)
        {
            return result;
        }

        // Later entries win: re-staging an index replaces the block, and if a
        // backend ever listed both versions, the newest is the one Commit uses.
        foreach (var block in list.UncommittedBlocks)
        {
            if (ParseBlockId(block.Name) is { } index) result[index] = block.SizeLong;
        }
        return result;
    }

    /// <summary>
    /// Deletes the blob AND any uncommitted blocks. Deleting a blob that only
    /// has uncommitted blocks is a no-op in Azure (the blob "does not exist"),
    /// and Azure then keeps those blocks for up to 7 days, still billed. So
    /// when uncommitted blocks exist they are first turned into an empty
    /// committed blob (Commit with an empty list discards them), which can then
    /// be deleted. Idempotent: a missing blob or container is success.
    /// </summary>
    public static async Task DeleteWithBlocksAsync(BlockBlobClient blob, CancellationToken ct)
    {
        try
        {
            var list = (await blob.GetBlockListAsync(BlockListTypes.Uncommitted, cancellationToken: ct)).Value;
            if (list.UncommittedBlocks.Any())
                await blob.CommitBlockListAsync([], new CommitBlockListOptions(), ct);
        }
        catch (RequestFailedException e) when (e.Status == 404)
        {
            // Neither blob nor blocks (or no container yet): nothing to release.
        }

        await blob.DeleteIfExistsAsync(cancellationToken: ct);
    }
}
