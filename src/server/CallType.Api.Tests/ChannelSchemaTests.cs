// ---------------------------------------------------------------------------
// ChannelSchemaTests.cs — Integration tests for the channel tables' constraints
// ---------------------------------------------------------------------------
// The "one reaction / one vote / one follow per device" rules and the unique
// channel handle are enforced by the DATABASE (composite PKs, unique index),
// not by application code. Only a real PostgreSQL proves they are really there.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests;

public class ChannelSchemaTests : IntegrationTestBase
{
    private static Account NewAccount() => new()
    {
        AccountId = Guid.NewGuid(),
        Email = $"{Guid.NewGuid():N}@example.com",
        AuthKeyHash = [0x01],
        CreatedAt = DateTimeOffset.UtcNow
    };

    private static Device NewDevice(string handle) => new()
    {
        DeviceId = Guid.NewGuid(),
        UserHandle = handle,
        IdentityKey = [0x01],
        SignedPreKey = [0x02],
        DeviceSecretHash = new byte[32],
        CreatedAt = DateTimeOffset.UtcNow,
        LastSeenAt = DateTimeOffset.UtcNow
    };

    private static Channel NewChannel(Account owner, string handle) => new()
    {
        ChannelId = Guid.NewGuid(),
        Handle = handle,
        Name = "News",
        OwnerDeviceId = Guid.NewGuid(),
        OwnerAccount = owner,
        CreatedAt = DateTimeOffset.UtcNow
    };

    // Each attempt uses a fresh context: after a failed SaveChanges the tracker
    // still holds the rejected entity and would poison the next assertion.
    private AppDbContext NewDb(IServiceScope scope) =>
        new(scope.ServiceProvider.GetRequiredService<DbContextOptions<AppDbContext>>());

    [Fact]
    public async Task Channel_handle_unique_constraint_prevents_duplicates()
    {
        using var scope = Factory.Services.CreateScope();
        await using var db = NewDb(scope);
        var owner = NewAccount();
        db.Channels.Add(NewChannel(owner, "CH-AAAA-BBBB"));
        await db.SaveChangesAsync();

        db.Channels.Add(NewChannel(owner, "CH-AAAA-BBBB"));
        var act = () => db.SaveChangesAsync();

        await act.Should().ThrowAsync<DbUpdateException>();
    }

    [Fact]
    public async Task Post_round_trips_kind_as_text_and_keeps_client_generated_id()
    {
        using var scope = Factory.Services.CreateScope();
        await using var db = NewDb(scope);
        var channel = NewChannel(NewAccount(), "CH-CCCC-DDDD");
        var postId = Guid.NewGuid();
        channel.Posts.Add(new ChannelPost
        {
            PostId = postId, AuthorDeviceId = Guid.NewGuid(), Kind = ChannelPostKind.Poll,
            Body = "{}", CreatedAt = DateTimeOffset.UtcNow
        });
        db.Channels.Add(channel);
        await db.SaveChangesAsync();

        await using var verifyDb = NewDb(scope);
        (await verifyDb.ChannelPosts.SingleAsync(p => p.PostId == postId)).Kind.Should().Be(ChannelPostKind.Poll);
        // Stored as readable text, not as the enum's number.
        var raw = await verifyDb.Database
            .SqlQuery<string>($"""SELECT "Kind" AS "Value" FROM "ChannelPosts" WHERE "PostId" = {postId}""")
            .SingleAsync();
        raw.Should().Be("Poll");
    }

    [Fact]
    public async Task Composite_keys_allow_one_follow_admin_reaction_and_vote_per_device()
    {
        using var scope = Factory.Services.CreateScope();
        var device = NewDevice("CT-EEEE-FFFF");
        var channel = NewChannel(NewAccount(), "CH-EEEE-FFFF");
        var post = new ChannelPost
        {
            PostId = Guid.NewGuid(), AuthorDeviceId = device.DeviceId, Kind = ChannelPostKind.Text,
            Body = "hi", CreatedAt = DateTimeOffset.UtcNow
        };
        channel.Posts.Add(post);

        await using (var db = NewDb(scope))
        {
            db.Devices.Add(device);
            db.Channels.Add(channel);
            db.ChannelFollowers.Add(new ChannelFollower { ChannelId = channel.ChannelId, DeviceId = device.DeviceId, FollowedAt = DateTimeOffset.UtcNow });
            db.ChannelAdmins.Add(new ChannelAdmin { ChannelId = channel.ChannelId, DeviceId = device.DeviceId, Role = "owner", AddedAt = DateTimeOffset.UtcNow });
            db.ChannelReactions.Add(new ChannelReaction { PostId = post.PostId, DeviceId = device.DeviceId, Emoji = "👍", CreatedAt = DateTimeOffset.UtcNow });
            db.ChannelPollVotes.Add(new ChannelPollVote { PostId = post.PostId, DeviceId = device.DeviceId, OptionIndex = 0 });
            await db.SaveChangesAsync();
        }

        // A second row with the same composite key must be rejected for each table.
        var duplicates = new object[]
        {
            new ChannelFollower { ChannelId = channel.ChannelId, DeviceId = device.DeviceId, FollowedAt = DateTimeOffset.UtcNow },
            new ChannelAdmin { ChannelId = channel.ChannelId, DeviceId = device.DeviceId, AddedAt = DateTimeOffset.UtcNow },
            new ChannelReaction { PostId = post.PostId, DeviceId = device.DeviceId, Emoji = "❤", CreatedAt = DateTimeOffset.UtcNow },
            new ChannelPollVote { PostId = post.PostId, DeviceId = device.DeviceId, OptionIndex = 1 }
        };
        foreach (var duplicate in duplicates)
        {
            await using var db = NewDb(scope);
            db.Add(duplicate);
            var act = () => db.SaveChangesAsync();
            await act.Should().ThrowAsync<DbUpdateException>($"{duplicate.GetType().Name} has a composite primary key");
        }
    }

    [Fact]
    public async Task Report_survives_without_a_post_and_is_removed_with_its_channel()
    {
        using var scope = Factory.Services.CreateScope();
        var channel = NewChannel(NewAccount(), "CH-GGGG-HHHH");
        await using (var db = NewDb(scope))
        {
            db.Channels.Add(channel);
            // PostId points at nothing on purpose — it is not a foreign key, so
            // a report outlives a post removed by retention.
            db.ChannelReports.Add(new ChannelReport
            {
                ChannelId = channel.ChannelId, PostId = Guid.NewGuid(), ReporterDeviceId = Guid.NewGuid(),
                Reason = "spam", CreatedAt = DateTimeOffset.UtcNow
            });
            await db.SaveChangesAsync();
        }

        await using var verifyDb = NewDb(scope);
        (await verifyDb.ChannelReports.CountAsync(r => r.ChannelId == channel.ChannelId)).Should().Be(1);

        await verifyDb.Channels.Where(c => c.ChannelId == channel.ChannelId).ExecuteDeleteAsync();
        (await verifyDb.ChannelReports.CountAsync(r => r.ChannelId == channel.ChannelId)).Should().Be(0);
    }

    [Fact]
    public async Task Account_owning_a_channel_cannot_be_deleted()
    {
        using var scope = Factory.Services.CreateScope();
        var owner = NewAccount();
        await using (var db = NewDb(scope))
        {
            db.Channels.Add(NewChannel(owner, "CH-JJJJ-KKKK"));
            await db.SaveChangesAsync();
        }

        // Restrict FK: a public channel must never disappear as a side effect.
        await using var deleteDb = NewDb(scope);
        var act = () => deleteDb.Accounts.Where(a => a.AccountId == owner.AccountId).ExecuteDeleteAsync();
        await act.Should().ThrowAsync<Exception>();
    }
}
