// ---------------------------------------------------------------------------
// MediaEndpoints.cs - Chunked upload/download of end-to-end encrypted media
// ---------------------------------------------------------------------------
// Contract: docs/superpowers/specs/2026-11-07-encrypted-media.md section 2.
//
//   POST   /media                      create an upload (quota checked here)
//   PUT    /media/{id}/chunks/{index}  stage one encrypted chunk (uploader)
//   GET    /media/{id}/upload          resume state (uploader)
//   POST   /media/{id}/complete        commit the block list (uploader)
//   DELETE /media/{id}                 cancel / delete (uploader)
//   GET    /media/{id}                 download, Range aware (any device)
//
// The server only ever sees ciphertext. Bytes go through the API instead of
// Blob SAS URLs (spec M2): the API can enforce exact chunk lengths, the
// declared size, the quotas and the 5 GB cap, a write SAS cannot.
//
// Uploader-only routes answer 404 media_not_found to every other device, the
// same as for an unknown id, so they are no oracle for which ids exist.
// Download is a capability (spec M3): knowing the random id (which only ever
// travels inside E2E messages) is the authorization.
// ---------------------------------------------------------------------------

using System.Data;
using System.Security.Claims;
using System.Text.Json.Serialization;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using Microsoft.Net.Http.Headers;
using Npgsql;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class MediaEndpoints
{
    /// <summary>Encrypted chunk bounds: 1 MiB .. 8 MiB plaintext + 16-byte GCM tag (spec section 1).</summary>
    public const int MinChunkSize = 1024 * 1024 + 16;
    public const int MaxChunkSize = 8 * 1024 * 1024 + 16;

    /// <summary>The smallest possible file: one empty final chunk = just its tag.</summary>
    public const long MinSize = 16;

    // Read buffer of a chunk PUT (and the initial buffer size).
    private const int ChunkReadSize = 256 * 1024;

    // Rolling window of the daily caps; also how long a Deleted row is kept.
    internal static readonly TimeSpan DailyWindow = TimeSpan.FromHours(24);

    public static WebApplication MapMediaEndpoints(this WebApplication app)
    {
        // "media" (600/min per device) only on the two byte-moving routes:
        // a 5 GB file is ~1280 chunk PUTs, far beyond the general "api" budget.
        app.MapPost("/media", Create).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/media/{id:guid}/chunks/{index:int}", UploadChunk).RequireAuthorization().RequireRateLimiting("media");
        app.MapGet("/media/{id:guid}/upload", UploadState).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/media/{id:guid}/complete", Complete).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/media/{id:guid}", Delete).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/media/{id:guid}", Download).RequireAuthorization().RequireRateLimiting("media");
        return app;
    }

    private static IResult Error(int status, string code, string message) =>
        Results.Json(new { error = message, code }, statusCode: status);

    private static IResult NotFound() => Error(StatusCodes.Status404NotFound, "media_not_found", "Media not found.");

    /// <summary>The caller's own, not-yet-forgotten upload; null for unknown ids and other devices' media.</summary>
    private static async Task<MediaUpload?> FindOwnAsync(AppDbContext db, ClaimsPrincipal user, Guid id, CancellationToken ct)
    {
        var caller = AccountEndpoints.CallerDeviceId(user);
        return await db.MediaUploads.FirstOrDefaultAsync(m => m.Id == id && m.UploaderDeviceId == caller, ct);
    }

    // -----------------------------------------------------------------------
    // POST /media
    // -----------------------------------------------------------------------
    private static async Task<IResult> Create(
        CreateMediaRequest request, ClaimsPrincipal user, AppDbContext db, BlobServiceClient blobService,
        IOptions<MediaOptions> options, TimeProvider clock, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } deviceId) return Results.Unauthorized();
        var limits = options.Value;

        if (request.ChunkSize is < MinChunkSize or > MaxChunkSize || request.Size < MinSize)
            return Error(StatusCodes.Status400BadRequest, "invalid_media_size", "Invalid size or chunk size.");
        if (request.Size > limits.MaxFileBytes)
            return Error(StatusCodes.Status413PayloadTooLarge, "media_too_large", "File is too large.");

        var now = clock.GetUtcNow();
        var media = new MediaUpload
        {
            Id = Guid.NewGuid(),
            UploaderDeviceId = deviceId,
            SizeBytes = request.Size,
            ChunkSize = request.ChunkSize,
            Status = MediaStatus.Uploading,
            CreatedAt = now,
            ExpiresAt = now.AddHours(limits.UploadWindowHours)
        };

        await using (var tx = await db.Database.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct))
        {
            // Row lock on the caller's Device row serialises concurrent creates of
            // ONE device, so two requests cannot both see the last free slot and
            // both insert. Under READ COMMITTED every statement after the lock
            // sees the rows the previous holder committed. The global cap is not
            // serialised across devices on purpose: a global lock would put every
            // upload in the installation behind one row, and the possible
            // overshoot (one file per concurrently creating device) is harmless
            // for a cost bound of hundreds of GiB.
            var locked = await db.Database.SqlQueryRaw<Guid>(
                    """SELECT "DeviceId" AS "Value" FROM "Devices" WHERE "DeviceId" = @deviceId FOR UPDATE""",
                    new NpgsqlParameter("@deviceId", deviceId))
                .ToListAsync(ct);
            // A valid JWT of a device deleted since (N09) must not create orphans.
            if (locked.Count == 0) return Results.Unauthorized();

            var active = db.MediaUploads.Where(m =>
                (m.Status == MediaStatus.Uploading || m.Status == MediaStatus.Completed) && m.ExpiresAt > now);

            var deviceActiveBytes = await active.Where(m => m.UploaderDeviceId == deviceId).SumAsync(m => m.SizeBytes, ct);
            if (deviceActiveBytes + request.Size > limits.MaxActiveBytesPerDevice)
                return Error(StatusCodes.Status409Conflict, "media_quota_exceeded", "Media storage quota of this device exceeded.");

            // Every status counts here, Deleted included: the daily caps are about
            // what was CREATED, otherwise create + delete loops would bypass them.
            var since = now - DailyWindow;
            var createdToday = db.MediaUploads.Where(m => m.UploaderDeviceId == deviceId && m.CreatedAt > since);
            var dailyCount = await createdToday.CountAsync(ct);
            var dailyBytes = await createdToday.SumAsync(m => m.SizeBytes, ct);
            if (dailyCount >= limits.MaxUploadsPerDay || dailyBytes + request.Size > limits.MaxDailyBytesPerDevice)
                return Error(StatusCodes.Status429TooManyRequests, "media_rate_limited", "Too many media uploads, try again later.");

            var totalActiveBytes = await active.SumAsync(m => m.SizeBytes, ct);
            if (totalActiveBytes + request.Size > limits.MaxTotalBytes)
                return Error(StatusCodes.Status503ServiceUnavailable, "media_storage_full", "Media storage is full, try again later.");

            db.MediaUploads.Add(media);
            await db.SaveChangesAsync(ct);
            await tx.CommitAsync(ct);
        }

        // Created on first use instead of at startup (same as backups): no
        // startup dependency on Blob storage, and the call is idempotent.
        await blobService.GetBlobContainerClient(MediaBlobStore.ContainerName).CreateIfNotExistsAsync(cancellationToken: ct);

        return Results.Created($"/media/{media.Id}",
            new CreateMediaResponse(media.Id, media.ChunkSize, media.ChunkCount, media.ExpiresAt));
    }

    // -----------------------------------------------------------------------
    // PUT /media/{id}/chunks/{index}
    // -----------------------------------------------------------------------
    private static async Task<IResult> UploadChunk(
        Guid id, int index, HttpRequest httpRequest, ClaimsPrincipal user, AppDbContext db,
        BlobServiceClient blobService, IOptions<MediaOptions> options, TimeProvider clock, CancellationToken ct)
    {
        // Fixed-window rate limits count requests, not how long they stay
        // open: without this a device could hold thousands of slow PUTs.
        if (AccountEndpoints.CallerDeviceId(user) is not { } caller) return NotFound();
        if (!ChunkUploadGate.TryEnter(caller, options.Value.MaxConcurrentChunkUploadsPerDevice))
            return Error(StatusCodes.Status429TooManyRequests, "media_rate_limited", "Too many chunk uploads in progress.");
        try
        {
            return await UploadChunkCore(id, index, httpRequest, user, db, blobService, clock, ct);
        }
        finally
        {
            ChunkUploadGate.Exit(caller);
        }
    }

    private static async Task<IResult> UploadChunkCore(
        Guid id, int index, HttpRequest httpRequest, ClaimsPrincipal user, AppDbContext db,
        BlobServiceClient blobService, TimeProvider clock, CancellationToken ct)
    {
        var media = await FindOwnAsync(db, user, id, ct);
        if (media is null) return NotFound();
        if (media.Status != MediaStatus.Uploading)
            return Error(StatusCodes.Status409Conflict, "media_not_uploading", "Upload is not in progress.");
        if (clock.GetUtcNow() >= media.ExpiresAt)
            return Error(StatusCodes.Status410Gone, "media_expired", "Upload window has passed.");
        if (index < 0 || index >= media.ChunkCount)
            return Error(StatusCodes.Status400BadRequest, "invalid_chunk", "Chunk index out of range.");

        var expected = media.ExpectedChunkLength(index);
        // Checked up front so a wrong client is rejected before any byte is
        // read; the read below re-checks, since Content-Length is only a claim.
        if (httpRequest.ContentLength != expected)
            return Error(StatusCodes.Status400BadRequest, "invalid_chunk", "Chunk length does not match.");

        // One chunk (<= 8 MiB + 16) is buffered so StageBlock gets a seekable
        // stream it can retry. The buffer grows with the bytes that actually
        // arrive (a client that announces 8 MiB and trickles pins only what it
        // sent). Reading stops at expected + 1 bytes: the +1 only detects an
        // over-long body, the rest of such a body is never read.
        using var content = new MemoryStream(capacity: (int)Math.Min(expected, ChunkReadSize));
        var buffer = new byte[ChunkReadSize];
        while (content.Length <= expected)
        {
            var want = (int)Math.Min(buffer.Length, expected + 1 - content.Length);
            var n = await httpRequest.Body.ReadAsync(buffer.AsMemory(0, want), ct);
            if (n == 0) break;
            content.Write(buffer, 0, n);
        }
        if (content.Length != expected)
            return Error(StatusCodes.Status400BadRequest, "invalid_chunk", "Chunk length does not match.");

        // Fixed block id per index: re-uploading the same index replaces the
        // block, which makes retries and resume idempotent (spec M4).
        var blob = MediaBlobStore.GetBlob(blobService, media.Id);
        content.Position = 0;
        await blob.StageBlockAsync(MediaBlobStore.BlockId(index), content, new BlockBlobStageBlockOptions(), ct);

        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // GET /media/{id}/upload
    // -----------------------------------------------------------------------
    private static async Task<IResult> UploadState(
        Guid id, ClaimsPrincipal user, AppDbContext db, BlobServiceClient blobService,
        IOptions<MediaOptions> options, TimeProvider clock, CancellationToken ct)
    {
        var media = await FindOwnAsync(db, user, id, ct);
        // A cancelled upload has nothing to resume; to the client it is gone.
        if (media is null || media.Status == MediaStatus.Deleted) return NotFound();
        // Past the upload window (cleanup not run yet): gone as well, so the
        // client starts a new upload instead of failing on every chunk.
        if (media.Status == MediaStatus.Uploading && clock.GetUtcNow() >= media.ExpiresAt)
            return Error(StatusCodes.Status410Gone, "media_expired", "Upload window has passed.");

        // The upload deadline is not stored once ExpiresAt switches to the
        // retention end on completion, so it is derived from CreatedAt.
        var uploadExpiresAt = media.Status == MediaStatus.Uploading
            ? media.ExpiresAt
            : media.CreatedAt.AddHours(options.Value.UploadWindowHours);

        List<int> received;
        if (media.Status == MediaStatus.Completed)
        {
            received = Enumerable.Range(0, media.ChunkCount).ToList();
        }
        else
        {
            var staged = await MediaBlobStore.GetStagedChunksAsync(MediaBlobStore.GetBlob(blobService, media.Id), ct);
            received = ValidChunks(media, staged);
        }

        return Results.Ok(new MediaUploadStateResponse(
            media.Id,
            media.Status == MediaStatus.Completed ? "completed" : "uploading",
            media.ChunkCount,
            received,
            uploadExpiresAt,
            media.Status == MediaStatus.Completed ? media.ExpiresAt : null));
    }

    /// <summary>Staged chunk indexes in range and with exactly the expected length, ascending.</summary>
    private static List<int> ValidChunks(MediaUpload media, Dictionary<int, long> staged) =>
        staged
            .Where(kv => kv.Key < media.ChunkCount && kv.Value == media.ExpectedChunkLength(kv.Key))
            .Select(kv => kv.Key)
            .Order()
            .ToList();

    // -----------------------------------------------------------------------
    // POST /media/{id}/complete
    // -----------------------------------------------------------------------
    private static async Task<IResult> Complete(
        Guid id, ClaimsPrincipal user, AppDbContext db, BlobServiceClient blobService,
        IOptions<MediaOptions> options, TimeProvider clock, CancellationToken ct)
    {
        var media = await FindOwnAsync(db, user, id, ct);
        if (media is null) return NotFound();

        // Idempotent: a retry after a lost response gets the same answer.
        if (media.Status == MediaStatus.Completed)
            return Results.Ok(new CompleteMediaResponse(media.Id, media.SizeBytes, media.ExpiresAt));
        if (media.Status != MediaStatus.Uploading)
            return Error(StatusCodes.Status409Conflict, "media_not_uploading", "Upload is not in progress.");

        var now = clock.GetUtcNow();
        if (now >= media.ExpiresAt)
            return Error(StatusCodes.Status410Gone, "media_expired", "Upload window has passed.");

        var blob = MediaBlobStore.GetBlob(blobService, media.Id);
        var received = ValidChunks(media, await MediaBlobStore.GetStagedChunksAsync(blob, ct)).ToHashSet();
        var missing = Enumerable.Range(0, media.ChunkCount).Where(i => !received.Contains(i)).ToList();
        if (missing.Count > 0)
            return Results.Json(new MediaIncompleteError("Some chunks are missing.", "media_incomplete", missing),
                statusCode: StatusCodes.Status409Conflict);

        // Index order = byte order of the ciphertext stream (C_0 || C_1 || ...).
        await blob.CommitBlockListAsync(
            Enumerable.Range(0, media.ChunkCount).Select(MediaBlobStore.BlockId),
            new CommitBlockListOptions(), ct);

        media.Status = MediaStatus.Completed;
        media.CompletedAt = now;
        media.ExpiresAt = now.AddHours(options.Value.RetentionHours);
        await db.SaveChangesAsync(ct);

        return Results.Ok(new CompleteMediaResponse(media.Id, media.SizeBytes, media.ExpiresAt));
    }

    // -----------------------------------------------------------------------
    // DELETE /media/{id}
    // -----------------------------------------------------------------------
    private static async Task<IResult> Delete(
        Guid id, ClaimsPrincipal user, AppDbContext db, BlobServiceClient blobService,
        ILoggerFactory loggerFactory, CancellationToken ct)
    {
        var media = await FindOwnAsync(db, user, id, ct);
        if (media is null) return NotFound();
        if (media.Status == MediaStatus.Deleted) return Results.NoContent();

        // Row first: from here on the media is not downloadable and not
        // counted as active storage, even if the blob call below fails.
        // The row itself stays until CreatedAt + 24 h (daily caps) and
        // MediaCleanupService retries the blob deletion before removing it.
        media.Status = MediaStatus.Deleted;
        await db.SaveChangesAsync(ct);

        try
        {
            await MediaBlobStore.DeleteWithBlocksAsync(MediaBlobStore.GetBlob(blobService, media.Id), ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            loggerFactory.CreateLogger("CallType.Api.Media")
                .LogWarning(ex, "Media blob {MediaId} could not be deleted now; cleanup will retry.", media.Id);
        }

        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // GET /media/{id}
    // -----------------------------------------------------------------------
    private static async Task<IResult> Download(
        Guid id, HttpContext http, AppDbContext db, BlobServiceClient blobService,
        TimeProvider clock, CancellationToken ct)
    {
        var media = await db.MediaUploads.AsNoTracking().FirstOrDefaultAsync(m => m.Id == id, ct);
        if (media is null || media.Status != MediaStatus.Completed) return NotFound();
        // Past retention but cleanup has not run yet: "gone", so the client
        // shows "expired" instead of retrying.
        if (clock.GetUtcNow() >= media.ExpiresAt)
            return Error(StatusCodes.Status410Gone, "media_expired", "Media has expired.");

        var total = media.SizeBytes;
        long from = 0, to = total - 1;
        var partial = false;

        // Only a single "bytes=a-" or "bytes=a-b" range is served as 206 (download
        // resume, spec 1). Anything else (suffix, multi-range, garbage) is
        // ignored and answered 200 with the whole body, as RFC 9110 allows.
        var range = http.Request.GetTypedHeaders().Range;
        if (range is { Unit.Value: "bytes", Ranges.Count: 1 } && range.Ranges.First().From is { } rangeFrom)
        {
            var rangeTo = range.Ranges.First().To;
            if (rangeFrom >= total)
            {
                http.Response.Headers[HeaderNames.ContentRange] = $"bytes */{total}";
                return Results.StatusCode(StatusCodes.Status416RangeNotSatisfiable);
            }
            from = rangeFrom;
            to = rangeTo is { } t && t < total - 1 ? t : total - 1;
            partial = true;
        }

        var blob = MediaBlobStore.GetBlob(blobService, media.Id);
        Azure.Response<BlobDownloadStreamingResult> download;
        try
        {
            download = await blob.DownloadStreamingAsync(
                new BlobDownloadOptions { Range = new Azure.HttpRange(from, to - from + 1) }, ct);
        }
        catch (Azure.RequestFailedException e) when (e.Status == StatusCodes.Status404NotFound)
        {
            // The row says completed but the blob is gone (a cancel racing the
            // completion, manual cleanup): for the client that is "expired",
            // not a server error worth retrying.
            return NotFound();
        }

        var response = http.Response;
        response.StatusCode = partial ? StatusCodes.Status206PartialContent : StatusCodes.Status200OK;
        response.ContentType = "application/octet-stream";
        response.ContentLength = to - from + 1;
        response.Headers[HeaderNames.AcceptRanges] = "bytes";
        // Ciphertext with a capability URL: no shared or browser cache should keep it.
        response.Headers[HeaderNames.CacheControl] = "no-store";
        if (partial) response.Headers[HeaderNames.ContentRange] = $"bytes {from}-{to}/{total}";

        // Straight copy from the Blob response stream: never more than the copy
        // buffer in memory, whatever the file size.
        await using (var body = download.Value.Content)
        {
            await body.CopyToAsync(response.Body, ct);
        }
        return Results.Empty;
    }
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record CreateMediaRequest(long Size, int ChunkSize);

public record CreateMediaResponse(Guid Id, int ChunkSize, int ChunkCount, DateTimeOffset UploadExpiresAt);

public record MediaUploadStateResponse(
    Guid Id,
    string Status,
    int ChunkCount,
    List<int> Received,
    DateTimeOffset UploadExpiresAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] DateTimeOffset? ExpiresAt);

public record CompleteMediaResponse(Guid Id, long Size, DateTimeOffset ExpiresAt);

public record MediaIncompleteError(string Error, string Code, List<int> Missing);
