// ---------------------------------------------------------------------------
// ChannelPostCleanupServiceTests.cs — Integration tests for channel retention
// ---------------------------------------------------------------------------
// Runs the real service pass (RunOnceAsync, internal + InternalsVisibleTo)
// against real PostgreSQL and Azurite, because the behaviour under test is the
// combination "row gone AND blob gone" — a fake blob client would prove nothing.
// ---------------------------------------------------------------------------

using Azure.Storage.Blobs;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class ChannelPostCleanupServiceTests : IntegrationTestBase
{
    // Hosted services are registered as IHostedService, so that is the only
    // way to get the instance the application itself would run.
    private ChannelPostCleanupService Service =>
        Factory.Services.GetServices<IHostedService>().OfType<ChannelPostCleanupService>().Single();

    /// <summary>Creates account + channel, the minimum a post needs to satisfy its foreign keys.</summary>
    private async Task<Guid> CreateChannelAsync(AppDbContext db)
    {
        var account = new Account
        {
            AccountId = Guid.NewGuid(),
            Email = $"{Guid.NewGuid():N}@example.com",
            AuthKeyHash = [0x01],
            CreatedAt = DateTimeOffset.UtcNow
        };
        var channel = new Channel
        {
            ChannelId = Guid.NewGuid(),
            Handle = HandleGenerator.Generate(HandleGenerator.ChannelPrefix),
            Name = "Test channel",
            OwnerDeviceId = Guid.NewGuid(),
            OwnerAccount = account,
            CreatedAt = DateTimeOffset.UtcNow
        };
        db.Channels.Add(channel);
        await db.SaveChangesAsync();
        return channel.ChannelId;
    }

    private static ChannelPost Post(Guid channelId, int ageDays, string? blobPath = null) => new()
    {
        PostId = Guid.NewGuid(),
        ChannelId = channelId,
        AuthorDeviceId = Guid.NewGuid(),
        Kind = blobPath is null ? ChannelPostKind.Text : ChannelPostKind.Image,
        Body = "hello",
        AttachmentBlobPath = blobPath,
        CreatedAt = DateTimeOffset.UtcNow.AddDays(-ageDays)
    };

    [Fact]
    public async Task Cleanup_deletes_posts_past_retention_and_keeps_fresh_ones()
    {
        Guid oldId, freshId;
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var channelId = await CreateChannelAsync(db);
            var old = Post(channelId, ageDays: 91);     // default retention is 90 days
            var fresh = Post(channelId, ageDays: 89);
            (oldId, freshId) = (old.PostId, fresh.PostId);
            db.ChannelPosts.AddRange(old, fresh);
            await db.SaveChangesAsync();
        }

        var deleted = await Service.RunOnceAsync(CancellationToken.None);

        deleted.Should().Be(1);
        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await verifyDb.ChannelPosts.AnyAsync(p => p.PostId == oldId)).Should().BeFalse();
        (await verifyDb.ChannelPosts.AnyAsync(p => p.PostId == freshId)).Should().BeTrue();
    }

    [Fact]
    public async Task Cleanup_deletes_the_image_blob_of_an_expired_post_only()
    {
        var container = Factory.Services.GetRequiredService<BlobServiceClient>()
            .GetBlobContainerClient(ChannelPostCleanupService.ContainerName);
        await container.CreateIfNotExistsAsync();
        await container.UploadBlobAsync("old.jpg", BinaryData.FromBytes([0x01]));
        await container.UploadBlobAsync("fresh.jpg", BinaryData.FromBytes([0x02]));

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var channelId = await CreateChannelAsync(db);
            db.ChannelPosts.AddRange(
                // One path with and one without the container prefix — both forms are accepted.
                Post(channelId, ageDays: 120, blobPath: "channel-media/old.jpg"),
                Post(channelId, ageDays: 1, blobPath: "fresh.jpg"));
            await db.SaveChangesAsync();
        }

        await Service.RunOnceAsync(CancellationToken.None);

        (await container.GetBlobClient("old.jpg").ExistsAsync()).Value.Should().BeFalse();
        (await container.GetBlobClient("fresh.jpg").ExistsAsync()).Value.Should().BeTrue();
    }

    [Fact]
    public async Task Cleanup_handles_more_than_one_batch_and_cascades_reactions_and_votes()
    {
        Guid channelId;
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            channelId = await CreateChannelAsync(db);

            var device = new Device
            {
                DeviceId = Guid.NewGuid(),
                UserHandle = HandleGenerator.Generate(HandleGenerator.DevicePrefix),
                IdentityKey = [0x01],
                SignedPreKey = [0x02],
                DeviceSecretHash = new byte[32],
                CreatedAt = DateTimeOffset.UtcNow,
                LastSeenAt = DateTimeOffset.UtcNow
            };
            db.Devices.Add(device);

            // 150 > the service's batch size of 100, so the loop must run twice.
            var posts = Enumerable.Range(0, 150).Select(_ => Post(channelId, ageDays: 100)).ToList();
            db.ChannelPosts.AddRange(posts);
            db.ChannelReactions.Add(new ChannelReaction
            {
                PostId = posts[0].PostId, DeviceId = device.DeviceId, Emoji = "👍", CreatedAt = DateTimeOffset.UtcNow
            });
            db.ChannelPollVotes.Add(new ChannelPollVote
            {
                PostId = posts[1].PostId, DeviceId = device.DeviceId, OptionIndex = 0
            });
            await db.SaveChangesAsync();
        }

        var deleted = await Service.RunOnceAsync(CancellationToken.None);

        deleted.Should().Be(150);
        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await verifyDb.ChannelPosts.CountAsync(p => p.ChannelId == channelId)).Should().Be(0);
        (await verifyDb.ChannelReactions.CountAsync()).Should().Be(0);
        (await verifyDb.ChannelPollVotes.CountAsync()).Should().Be(0);

        // Re-running on an already clean table is a no-op, not an error.
        (await Service.RunOnceAsync(CancellationToken.None)).Should().Be(0);
    }
}
