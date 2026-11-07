// ---------------------------------------------------------------------------
// MediaCleanupServiceTests.cs - Integration tests for media retention (M5)
// ---------------------------------------------------------------------------
// Runs the real service pass (RunOnceAsync) against Postgres + Azurite with a
// FakeTimeProvider injected into a derived factory, so "72 hours later" is a
// clock move instead of a wait. HTTP calls happen only BEFORE the clock moves
// (tokens are minted on the real clock); afterwards the tests look at the
// database and the blob container directly.
// ---------------------------------------------------------------------------

using System.Net;
using Azure.Storage.Blobs;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using static CallType.Api.Tests.TestFixtures.MediaTestHelpers;

namespace CallType.Api.Tests.Services;

public class MediaCleanupServiceTests : IntegrationTestBase
{
    private (WebApplicationFactory<Program> Factory, FakeTimeProvider Clock, MediaCleanupService Service) Start()
    {
        var clock = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var factory = Factory.WithWebHostBuilder(b =>
            b.ConfigureServices(services => services.AddSingleton<TimeProvider>(clock)));
        // Hosted services are registered as IHostedService; that is the
        // instance the application itself runs.
        var service = factory.Services.GetServices<IHostedService>().OfType<MediaCleanupService>().Single();
        return (factory, clock, service);
    }

    private async Task<bool> RowExistsAsync(Guid id)
    {
        using var scope = Factory.Services.CreateScope();
        return await scope.ServiceProvider.GetRequiredService<AppDbContext>().MediaUploads.AnyAsync(m => m.Id == id);
    }

    private Azure.Storage.Blobs.Specialized.BlockBlobClient Blob(Guid id) =>
        MediaBlobStore.GetBlob(Factory.Services.GetRequiredService<BlobServiceClient>(), id);

    [Fact]
    public async Task Completed_media_is_deleted_with_its_blob_once_retention_has_passed()
    {
        var (factory, clock, service) = Start();
        await using var _ = factory;
        var device = await NewDeviceAsync(factory);
        var id = await UploadCompletedAsync(device.Http, Bytes(100));
        (await Blob(id).ExistsAsync()).Value.Should().BeTrue();

        clock.Advance(TimeSpan.FromHours(71));
        await service.RunOnceAsync(CancellationToken.None);
        (await RowExistsAsync(id)).Should().BeTrue("72 h retention has not passed yet");
        (await Blob(id).ExistsAsync()).Value.Should().BeTrue();

        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromMinutes(1));
        await service.RunOnceAsync(CancellationToken.None);
        (await RowExistsAsync(id)).Should().BeFalse();
        (await Blob(id).ExistsAsync()).Value.Should().BeFalse();
    }

    [Fact]
    public async Task Abandoned_upload_is_deleted_after_the_upload_window_and_its_blocks_are_released()
    {
        var (factory, clock, service) = Start();
        await using var _ = factory;
        var device = await NewDeviceAsync(factory);
        var id = await CreateOkAsync(device.Http, ChunkSize + 100);
        (await PutChunkAsync(device.Http, id, 1, Bytes(100))).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await MediaBlobStore.GetStagedChunksAsync(Blob(id), CancellationToken.None)).Should().ContainKey(1);

        clock.Advance(TimeSpan.FromHours(23));
        await service.RunOnceAsync(CancellationToken.None);
        (await RowExistsAsync(id)).Should().BeTrue("the 24 h upload window is still open");

        clock.Advance(TimeSpan.FromHours(1));
        await service.RunOnceAsync(CancellationToken.None);
        (await RowExistsAsync(id)).Should().BeFalse();
        // Uncommitted blocks are gone too (they would otherwise linger in Azure for 7 days).
        (await MediaBlobStore.GetStagedChunksAsync(Blob(id), CancellationToken.None)).Should().BeEmpty();
        (await Blob(id).ExistsAsync()).Value.Should().BeFalse();
    }

    [Fact]
    public async Task Deleted_rows_are_kept_for_24_hours_after_creation_for_the_daily_caps()
    {
        var (factory, clock, service) = Start();
        await using var _ = factory;
        var now = clock.GetUtcNow();
        var deleted = new MediaUpload
        {
            UploaderDeviceId = Guid.NewGuid(), SizeBytes = 100, ChunkSize = ChunkSize, Status = MediaStatus.Deleted,
            // Completed, then deleted: its ExpiresAt is far ahead, CreatedAt decides.
            CreatedAt = now, CompletedAt = now, ExpiresAt = now.AddHours(72)
        };
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.MediaUploads.Add(deleted);
            await db.SaveChangesAsync();
        }

        clock.Advance(TimeSpan.FromHours(23));
        await service.RunOnceAsync(CancellationToken.None);
        (await RowExistsAsync(deleted.Id)).Should().BeTrue();

        clock.Advance(TimeSpan.FromHours(1));
        await service.RunOnceAsync(CancellationToken.None);
        (await RowExistsAsync(deleted.Id)).Should().BeFalse();
    }

    [Fact]
    public async Task Cleanup_keeps_live_media_and_is_a_no_op_on_a_clean_table()
    {
        var (factory, _, service) = Start();
        await using var __ = factory;
        var device = await NewDeviceAsync(factory);
        var completed = await UploadCompletedAsync(device.Http, Bytes(100));
        var uploading = await CreateOkAsync(device.Http, 100);

        (await service.RunOnceAsync(CancellationToken.None)).Should().Be(0);

        (await RowExistsAsync(completed)).Should().BeTrue();
        (await RowExistsAsync(uploading)).Should().BeTrue();
        (await Blob(completed).ExistsAsync()).Value.Should().BeTrue();
    }

    [Fact]
    public async Task Cleanup_handles_more_than_one_batch()
    {
        var (factory, clock, service) = Start();
        await using var _ = factory;
        var now = clock.GetUtcNow();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            // 150 > the batch size of 100, so the loop must run twice. No blobs:
            // a missing blob is success (idempotent delete).
            db.MediaUploads.AddRange(Enumerable.Range(0, 150).Select(_ => new MediaUpload
            {
                UploaderDeviceId = Guid.NewGuid(), SizeBytes = 100, ChunkSize = ChunkSize,
                Status = MediaStatus.Uploading, CreatedAt = now.AddHours(-25), ExpiresAt = now.AddHours(-1)
            }));
            await db.SaveChangesAsync();
        }

        await service.RunOnceAsync(CancellationToken.None);

        using var verifyScope = Factory.Services.CreateScope();
        (await verifyScope.ServiceProvider.GetRequiredService<AppDbContext>().MediaUploads.CountAsync()).Should().Be(0);
    }
}
