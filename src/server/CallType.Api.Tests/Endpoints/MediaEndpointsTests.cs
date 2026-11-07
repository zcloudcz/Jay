// ---------------------------------------------------------------------------
// MediaEndpointsTests.cs - Integration tests for /media (encrypted media)
// ---------------------------------------------------------------------------
// Contract: docs/superpowers/specs/2026-11-07-encrypted-media.md section 2.
// Real Postgres + Azurite (IntegrationTestBase): staging, listing and
// committing blocks is exactly the behaviour under test, a fake blob client
// would prove nothing. Limits are overridden per test through a derived
// factory's configuration, so the quota tests need only a few hundred bytes.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Storage.Blobs;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using static CallType.Api.Tests.TestFixtures.MediaTestHelpers;

namespace CallType.Api.Tests.Endpoints;

public class MediaEndpointsTests : IntegrationTestBase
{
    /// <summary>A factory on the same databases with extra Media:* settings.</summary>
    private WebApplicationFactory<Program> WithSettings(params (string Key, string Value)[] settings) =>
        Factory.WithWebHostBuilder(b => b.ConfigureAppConfiguration((_, c) =>
            c.AddInMemoryCollection(settings.Select(s => new KeyValuePair<string, string?>(s.Key, s.Value)))));

    private async Task<MediaUpload> RowAsync(Guid id)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.MediaUploads.AsNoTracking().SingleAsync(m => m.Id == id);
    }

    private async Task UpdateRowAsync(Guid id, Action<MediaUpload> change)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var row = await db.MediaUploads.SingleAsync(m => m.Id == id);
        change(row);
        await db.SaveChangesAsync();
    }

    // ---------------------------------------------------------------- create

    [Fact]
    public async Task Create_returns_201_with_chunk_layout_and_upload_deadline()
    {
        var device = await NewDeviceAsync(Factory);
        var before = DateTimeOffset.UtcNow;

        var response = await CreateAsync(device.Http, size: 2L * ChunkSize + 100);

        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var id = body.GetProperty("id").GetGuid();
        response.Headers.Location!.ToString().Should().Be($"/media/{id}");
        body.GetProperty("chunkSize").GetInt32().Should().Be(ChunkSize);
        body.GetProperty("chunkCount").GetInt32().Should().Be(3);
        var uploadExpiresAt = body.GetProperty("uploadExpiresAt").GetDateTimeOffset();
        uploadExpiresAt.Offset.Should().Be(TimeSpan.Zero);
        uploadExpiresAt.Should().BeCloseTo(before.AddHours(24), TimeSpan.FromMinutes(1));

        var row = await RowAsync(id);
        row.UploaderDeviceId.Should().Be(device.DeviceId);
        row.Status.Should().Be(MediaStatus.Uploading);
        row.SizeBytes.Should().Be(2L * ChunkSize + 100);
    }

    [Theory]
    [InlineData(100L, ChunkSize - 1)]             // chunk below 1 MiB + 16
    [InlineData(100L, 8 * 1024 * 1024 + 17)]      // chunk above 8 MiB + 16
    [InlineData(15L, ChunkSize)]                  // smaller than one empty chunk
    [InlineData(0L, ChunkSize)]
    public async Task Create_rejects_invalid_sizes_with_400(long size, int chunkSize)
    {
        var device = await NewDeviceAsync(Factory);

        var response = await CreateAsync(device.Http, size, chunkSize);

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ErrorCodeAsync(response)).Should().Be("invalid_media_size");
    }

    [Fact]
    public async Task Create_accepts_the_boundary_chunk_sizes_and_the_empty_file()
    {
        var device = await NewDeviceAsync(Factory);

        (await CreateAsync(device.Http, 16, ChunkSize)).StatusCode.Should().Be(HttpStatusCode.Created);
        (await CreateAsync(device.Http, 100, 8 * 1024 * 1024 + 16)).StatusCode.Should().Be(HttpStatusCode.Created);
    }

    [Fact]
    public async Task Create_over_MaxFileBytes_is_413()
    {
        await using var factory = WithSettings(("Media:MaxFileBytes", "1000"));
        var device = await NewDeviceAsync(factory);

        (await CreateAsync(device.Http, 1000)).StatusCode.Should().Be(HttpStatusCode.Created);
        var response = await CreateAsync(device.Http, 1001);

        response.StatusCode.Should().Be(HttpStatusCode.RequestEntityTooLarge);
        (await ErrorCodeAsync(response)).Should().Be("media_too_large");
    }

    [Fact]
    public async Task Create_without_a_token_is_401()
    {
        var anonymous = Factory.CreateClient();
        (await CreateAsync(anonymous, 100)).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    // ------------------------------------------------------- full round trip

    [Fact]
    public async Task Upload_complete_and_download_by_another_device_round_trips_the_bytes()
    {
        var uploader = await NewDeviceAsync(Factory);
        var receiver = await NewDeviceAsync(Factory);
        var blob = Bytes(ChunkSize + 100);

        var id = await CreateOkAsync(uploader.Http, blob.Length);
        // Out of order on purpose: the commit must still be in index order.
        (await PutChunkAsync(uploader.Http, id, 1, blob[ChunkSize..])).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await PutChunkAsync(uploader.Http, id, 0, blob[..ChunkSize])).StatusCode.Should().Be(HttpStatusCode.NoContent);

        var complete = await uploader.Http.PostAsync($"/media/{id}/complete", null);
        complete.StatusCode.Should().Be(HttpStatusCode.OK);
        var completeBody = await complete.Content.ReadFromJsonAsync<JsonElement>();
        completeBody.GetProperty("id").GetGuid().Should().Be(id);
        completeBody.GetProperty("size").GetInt64().Should().Be(blob.Length);
        completeBody.GetProperty("expiresAt").GetDateTimeOffset()
            .Should().BeCloseTo(DateTimeOffset.UtcNow.AddHours(72), TimeSpan.FromMinutes(1));

        var download = await receiver.Http.GetAsync($"/media/{id}");
        download.StatusCode.Should().Be(HttpStatusCode.OK);
        download.Content.Headers.ContentType!.MediaType.Should().Be("application/octet-stream");
        download.Content.Headers.ContentLength.Should().Be(blob.Length);
        download.Headers.CacheControl!.NoStore.Should().BeTrue();
        download.Headers.AcceptRanges.Should().Contain("bytes");
        (await download.Content.ReadAsByteArrayAsync()).Should().Equal(blob);

        var row = await RowAsync(id);
        row.Status.Should().Be(MediaStatus.Completed);
        row.CompletedAt.Should().NotBeNull();
    }

    [Fact]
    public async Task Complete_is_idempotent_and_returns_the_same_body()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await UploadCompletedAsync(device.Http, Bytes(100));

        var first = await (await device.Http.PostAsync($"/media/{id}/complete", null)).Content.ReadAsStringAsync();
        var second = await device.Http.PostAsync($"/media/{id}/complete", null);

        second.StatusCode.Should().Be(HttpStatusCode.OK);
        (await second.Content.ReadAsStringAsync()).Should().Be(first);
    }

    [Fact]
    public async Task Download_with_range_answers_206_with_content_range()
    {
        var uploader = await NewDeviceAsync(Factory);
        var receiver = await NewDeviceAsync(Factory);
        var blob = Bytes(ChunkSize + 100, seed: 7);
        var id = await UploadCompletedAsync(uploader.Http, blob);

        // Resume form: "bytes=a-" (continue after the chunks already on disk).
        var open = new HttpRequestMessage(HttpMethod.Get, $"/media/{id}");
        open.Headers.Range = new RangeHeaderValue(ChunkSize, null);
        var tail = await receiver.Http.SendAsync(open);
        tail.StatusCode.Should().Be(HttpStatusCode.PartialContent);
        tail.Content.Headers.ContentRange!.ToString().Should().Be($"bytes {ChunkSize}-{blob.Length - 1}/{blob.Length}");
        tail.Content.Headers.ContentLength.Should().Be(100);
        (await tail.Content.ReadAsByteArrayAsync()).Should().Equal(blob[ChunkSize..]);

        // Closed form: "bytes=a-b".
        var closed = new HttpRequestMessage(HttpMethod.Get, $"/media/{id}");
        closed.Headers.Range = new RangeHeaderValue(10, 19);
        var middle = await receiver.Http.SendAsync(closed);
        middle.StatusCode.Should().Be(HttpStatusCode.PartialContent);
        middle.Content.Headers.ContentRange!.ToString().Should().Be($"bytes 10-19/{blob.Length}");
        (await middle.Content.ReadAsByteArrayAsync()).Should().Equal(blob[10..20]);

        // Start beyond the end: nothing to send.
        var beyond = new HttpRequestMessage(HttpMethod.Get, $"/media/{id}");
        beyond.Headers.Range = new RangeHeaderValue(blob.Length, null);
        (await receiver.Http.SendAsync(beyond)).StatusCode.Should().Be(HttpStatusCode.RequestedRangeNotSatisfiable);
    }

    [Fact]
    public async Task Download_without_a_token_is_401()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await UploadCompletedAsync(device.Http, Bytes(100));

        var anonymous = Factory.CreateClient();
        (await anonymous.GetAsync($"/media/{id}")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Download_of_unknown_or_unfinished_media_is_404()
    {
        var device = await NewDeviceAsync(Factory);
        var uploading = await CreateOkAsync(device.Http, 100);

        foreach (var id in new[] { Guid.NewGuid(), uploading })
        {
            var response = await device.Http.GetAsync($"/media/{id}");
            response.StatusCode.Should().Be(HttpStatusCode.NotFound);
            (await ErrorCodeAsync(response)).Should().Be("media_not_found");
        }
    }

    // ------------------------------------------------------ chunk validation

    [Fact]
    public async Task Chunk_with_wrong_length_or_index_is_400_invalid_chunk()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await CreateOkAsync(device.Http, ChunkSize + 100);

        var cases = new (int Index, int Length)[]
        {
            (0, ChunkSize - 1), // full chunk too short
            (0, ChunkSize + 1), // full chunk too long
            (1, 99),            // last chunk too short
            (1, 101),           // last chunk too long
            (1, ChunkSize),     // last chunk sent at full size
            (2, 100),           // index == chunkCount
        };
        foreach (var (index, length) in cases)
        {
            var response = await PutChunkAsync(device.Http, id, index, Bytes(length));
            response.StatusCode.Should().Be(HttpStatusCode.BadRequest, $"index {index}, length {length}");
            (await ErrorCodeAsync(response)).Should().Be("invalid_chunk");
        }

        var negative = await PutChunkAsync(device.Http, id, -1, Bytes(100));
        negative.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ErrorCodeAsync(negative)).Should().Be("invalid_chunk");

        // Nothing invalid was staged.
        var state = await device.Http.GetFromJsonAsync<JsonElement>($"/media/{id}/upload");
        state.GetProperty("received").GetArrayLength().Should().Be(0);
    }

    [Fact]
    public async Task Chunk_for_a_completed_upload_is_409_media_not_uploading()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await UploadCompletedAsync(device.Http, Bytes(100));

        var response = await PutChunkAsync(device.Http, id, 0, Bytes(100));

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ErrorCodeAsync(response)).Should().Be("media_not_uploading");
    }

    [Fact]
    public async Task Chunk_after_the_upload_window_is_410_media_expired()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await CreateOkAsync(device.Http, 100);
        await UpdateRowAsync(id, m => m.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1));

        var response = await PutChunkAsync(device.Http, id, 0, Bytes(100));

        response.StatusCode.Should().Be(HttpStatusCode.Gone);
        (await ErrorCodeAsync(response)).Should().Be("media_expired");
    }

    [Fact]
    public async Task Upload_state_after_the_upload_window_is_410_so_the_client_starts_over()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await CreateOkAsync(device.Http, 100);
        await UpdateRowAsync(id, m => m.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1));

        var response = await device.Http.GetAsync($"/media/{id}/upload");

        response.StatusCode.Should().Be(HttpStatusCode.Gone);
        (await ErrorCodeAsync(response)).Should().Be("media_expired");
    }

    [Fact]
    public async Task Chunk_puts_over_the_per_device_in_flight_cap_are_429()
    {
        var factory = WithSettings(("Media:MaxConcurrentChunkUploadsPerDevice", "0"));
        var device = await NewDeviceAsync(factory);
        var id = await CreateOkAsync(device.Http, 100);

        var response = await PutChunkAsync(device.Http, id, 0, Bytes(100));

        response.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        (await ErrorCodeAsync(response)).Should().Be("media_rate_limited");
    }

    [Fact]
    public void Chunk_upload_gate_counts_per_device_and_releases_slots()
    {
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        ChunkUploadGate.TryEnter(a, 2).Should().BeTrue();
        ChunkUploadGate.TryEnter(a, 2).Should().BeTrue();
        ChunkUploadGate.TryEnter(a, 2).Should().BeFalse();
        ChunkUploadGate.TryEnter(b, 2).Should().BeTrue();
        ChunkUploadGate.Exit(a);
        ChunkUploadGate.TryEnter(a, 2).Should().BeTrue();
        ChunkUploadGate.Exit(a);
        ChunkUploadGate.Exit(a);
        ChunkUploadGate.Exit(b);
        ChunkUploadGate.Exit(b); // extra exit is harmless
        ChunkUploadGate.TryEnter(b, 1).Should().BeTrue();
        ChunkUploadGate.Exit(b);
    }

    // ------------------------------------------------------- uploader-only

    [Fact]
    public async Task Uploader_only_routes_answer_404_to_other_devices_and_unknown_ids()
    {
        var uploader = await NewDeviceAsync(Factory);
        var other = await NewDeviceAsync(Factory);
        var id = await CreateOkAsync(uploader.Http, 100);

        foreach (var mediaId in new[] { id, Guid.NewGuid() })
        {
            var responses = new[]
            {
                await PutChunkAsync(other.Http, mediaId, 0, Bytes(100)),
                await other.Http.GetAsync($"/media/{mediaId}/upload"),
                await other.Http.PostAsync($"/media/{mediaId}/complete", null),
                await other.Http.DeleteAsync($"/media/{mediaId}"),
            };
            foreach (var response in responses)
            {
                response.StatusCode.Should().Be(HttpStatusCode.NotFound);
                (await ErrorCodeAsync(response)).Should().Be("media_not_found");
            }
        }

        // The foreign attempts changed nothing.
        (await RowAsync(id)).Status.Should().Be(MediaStatus.Uploading);
        var state = await uploader.Http.GetFromJsonAsync<JsonElement>($"/media/{id}/upload");
        state.GetProperty("received").GetArrayLength().Should().Be(0);
    }

    // ------------------------------------------------------------- resume

    [Fact]
    public async Task Upload_state_lists_received_chunks_and_complete_reports_missing()
    {
        var device = await NewDeviceAsync(Factory);
        var blob = Bytes(2 * ChunkSize + 100);
        var id = await CreateOkAsync(device.Http, blob.Length);

        (await PutChunkAsync(device.Http, id, 2, blob[(2 * ChunkSize)..])).StatusCode.Should().Be(HttpStatusCode.NoContent);
        // Re-uploading an index replaces it and is not listed twice.
        (await PutChunkAsync(device.Http, id, 2, blob[(2 * ChunkSize)..])).StatusCode.Should().Be(HttpStatusCode.NoContent);

        var state = await device.Http.GetFromJsonAsync<JsonElement>($"/media/{id}/upload");
        state.GetProperty("id").GetGuid().Should().Be(id);
        state.GetProperty("status").GetString().Should().Be("uploading");
        state.GetProperty("chunkCount").GetInt32().Should().Be(3);
        state.GetProperty("received").EnumerateArray().Select(e => e.GetInt32()).Should().Equal(2);
        state.TryGetProperty("uploadExpiresAt", out _).Should().BeTrue();
        state.TryGetProperty("expiresAt", out _).Should().BeFalse();

        var incomplete = await device.Http.PostAsync($"/media/{id}/complete", null);
        incomplete.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var body = await incomplete.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("code").GetString().Should().Be("media_incomplete");
        body.GetProperty("missing").EnumerateArray().Select(e => e.GetInt32()).Should().Equal(0, 1);

        // Resume: send the missing chunks, then completion works.
        (await PutChunkAsync(device.Http, id, 0, blob[..ChunkSize])).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await PutChunkAsync(device.Http, id, 1, blob[ChunkSize..(2 * ChunkSize)])).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await device.Http.PostAsync($"/media/{id}/complete", null)).StatusCode.Should().Be(HttpStatusCode.OK);

        var done = await device.Http.GetFromJsonAsync<JsonElement>($"/media/{id}/upload");
        done.GetProperty("status").GetString().Should().Be("completed");
        done.GetProperty("received").EnumerateArray().Select(e => e.GetInt32()).Should().Equal(0, 1, 2);
        done.TryGetProperty("expiresAt", out _).Should().BeTrue();

        var download = await device.Http.GetAsync($"/media/{id}");
        (await download.Content.ReadAsByteArrayAsync()).Should().Equal(blob);
    }

    // ------------------------------------------------------------- quotas

    [Fact]
    public async Task Per_device_active_bytes_over_quota_is_409_and_other_devices_are_unaffected()
    {
        await using var factory = WithSettings(("Media:MaxActiveBytesPerDevice", "1000"));
        var device = await NewDeviceAsync(factory);
        var other = await NewDeviceAsync(factory);

        await CreateOkAsync(device.Http, 600);
        var over = await CreateAsync(device.Http, 401);
        over.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ErrorCodeAsync(over)).Should().Be("media_quota_exceeded");

        // Exactly up to the quota is fine, and the quota is per device.
        await CreateOkAsync(device.Http, 400);
        await CreateOkAsync(other.Http, 1000);
    }

    [Fact]
    public async Task Uploads_per_day_over_the_cap_is_429()
    {
        await using var factory = WithSettings(("Media:MaxUploadsPerDay", "2"));
        var device = await NewDeviceAsync(factory);

        await CreateOkAsync(device.Http, 100);
        await CreateOkAsync(device.Http, 100);
        var third = await CreateAsync(device.Http, 100);

        third.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        (await ErrorCodeAsync(third)).Should().Be("media_rate_limited");
    }

    [Fact]
    public async Task Uploads_older_than_24_hours_do_not_count_for_the_daily_cap()
    {
        await using var factory = WithSettings(("Media:MaxUploadsPerDay", "1"));
        var device = await NewDeviceAsync(factory);
        var id = await CreateOkAsync(device.Http, 100);
        await UpdateRowAsync(id, m => m.CreatedAt = DateTimeOffset.UtcNow.AddHours(-25));

        await CreateOkAsync(device.Http, 100);
    }

    [Fact]
    public async Task Delete_marks_the_row_deleted_frees_active_bytes_but_still_counts_for_the_daily_cap()
    {
        await using var factory = WithSettings(
            ("Media:MaxActiveBytesPerDevice", "1000"),
            ("Media:MaxDailyBytesPerDevice", "1500"));
        var device = await NewDeviceAsync(factory);
        var id = await UploadCompletedAsync(device.Http, Bytes(800));

        var delete = await device.Http.DeleteAsync($"/media/{id}");
        delete.StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await device.Http.DeleteAsync($"/media/{id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await RowAsync(id)).Status.Should().Be(MediaStatus.Deleted);
        var blob = Factory.Services.GetRequiredService<BlobServiceClient>()
            .GetBlobContainerClient(MediaBlobStore.ContainerName).GetBlobClient(id.ToString());
        (await blob.ExistsAsync()).Value.Should().BeFalse();
        (await device.Http.GetAsync($"/media/{id}")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await device.Http.GetAsync($"/media/{id}/upload")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        var chunk = await PutChunkAsync(device.Http, id, 0, Bytes(800));
        chunk.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await ErrorCodeAsync(chunk)).Should().Be("media_not_uploading");

        // 800 deleted bytes no longer count as active (1000 cap) ...
        await CreateOkAsync(device.Http, 600);
        // ... but they still count for the daily 1500: 800 + 600 + 101 > 1500.
        var over = await CreateAsync(device.Http, 101);
        over.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        (await ErrorCodeAsync(over)).Should().Be("media_rate_limited");
    }

    [Fact]
    public async Task Delete_of_an_unfinished_upload_releases_its_uncommitted_blocks()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await CreateOkAsync(device.Http, ChunkSize + 100);
        (await PutChunkAsync(device.Http, id, 1, Bytes(100))).StatusCode.Should().Be(HttpStatusCode.NoContent);
        var blob = MediaBlobStore.GetBlob(Factory.Services.GetRequiredService<BlobServiceClient>(), id);
        (await MediaBlobStore.GetStagedChunksAsync(blob, CancellationToken.None)).Should().ContainKey(1);

        (await device.Http.DeleteAsync($"/media/{id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await MediaBlobStore.GetStagedChunksAsync(blob, CancellationToken.None)).Should().BeEmpty();
        (await blob.ExistsAsync()).Value.Should().BeFalse();
    }

    [Fact]
    public async Task Global_active_bytes_over_MaxTotalBytes_is_503()
    {
        await using var factory = WithSettings(("Media:MaxTotalBytes", "1000"));
        var first = await NewDeviceAsync(factory);
        var second = await NewDeviceAsync(factory);

        await CreateOkAsync(first.Http, 600);
        var full = await CreateAsync(second.Http, 600);

        full.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        (await ErrorCodeAsync(full)).Should().Be("media_storage_full");
    }

    [Fact]
    public async Task Concurrent_creates_of_one_device_cannot_both_take_the_last_slot()
    {
        await using var factory = WithSettings(("Media:MaxUploadsPerDay", "1"));
        var device = await NewDeviceAsync(factory);

        var responses = await Task.WhenAll(Enumerable.Range(0, 6).Select(_ => CreateAsync(device.Http, 100)));

        responses.Count(r => r.StatusCode == HttpStatusCode.Created).Should().Be(1);
        responses.Count(r => r.StatusCode == HttpStatusCode.TooManyRequests).Should().Be(5);
    }

    // ------------------------------------------------------------- expiry

    [Fact]
    public async Task Expired_media_is_410_before_cleanup_and_404_after()
    {
        var uploader = await NewDeviceAsync(Factory);
        var receiver = await NewDeviceAsync(Factory);
        var id = await UploadCompletedAsync(uploader.Http, Bytes(100));
        await UpdateRowAsync(id, m => m.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1));

        var expired = await receiver.Http.GetAsync($"/media/{id}");
        expired.StatusCode.Should().Be(HttpStatusCode.Gone);
        (await ErrorCodeAsync(expired)).Should().Be("media_expired");

        var cleanup = Factory.Services.GetServices<IHostedService>().OfType<MediaCleanupService>().Single();
        await cleanup.RunOnceAsync(CancellationToken.None);

        var gone = await receiver.Http.GetAsync($"/media/{id}");
        gone.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ErrorCodeAsync(gone)).Should().Be("media_not_found");
    }

    [Fact]
    public async Task Download_of_completed_media_whose_blob_is_gone_is_404_not_500()
    {
        var uploader = await NewDeviceAsync(Factory);
        var receiver = await NewDeviceAsync(Factory);
        var id = await UploadCompletedAsync(uploader.Http, Bytes(100));
        var blobs = Factory.Services.GetRequiredService<BlobServiceClient>();
        await MediaBlobStore.GetBlob(blobs, id).DeleteIfExistsAsync();

        var response = await receiver.Http.GetAsync($"/media/{id}");

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await ErrorCodeAsync(response)).Should().Be("media_not_found");
    }

    // ---------------------------------------------------------------- CORS

    [Fact]
    public async Task Cors_exposes_the_range_headers_to_browsers()
    {
        var device = await NewDeviceAsync(Factory);
        var id = await UploadCompletedAsync(device.Http, Bytes(100));

        var request = new HttpRequestMessage(HttpMethod.Get, $"/media/{id}");
        request.Headers.Add("Origin", "http://localhost:3000");
        var response = await device.Http.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var exposed = string.Join(",", response.Headers.GetValues("Access-Control-Expose-Headers"));
        exposed.Should().Contain("Content-Length").And.Contain("Content-Range").And.Contain("Accept-Ranges");
    }
}
