// ---------------------------------------------------------------------------
// ChannelEndpointsTests.cs — Integration tests for public channels
// ---------------------------------------------------------------------------
// Covers the acceptance criteria of docs/superpowers/plans/2026-09-16-channels.md
// §6 (+ §7 decisions) against real PostgreSQL and Azurite (Testcontainers) and
// a real SignalR client, the same way BackupEndpointsTests / MessengerHubTests do.
//
// Several devices act in one test, so instead of the shared Client each device
// gets its own HttpClient with its own JWT (NewDeviceAsync). Every response
// goes through SendAsync, which records the raw body — the anonymity test then
// scans ALL of them for device ids that do not belong to the caller.
//
// Each test stays well under the 100 req/min "api" rate limit per device.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class ChannelEndpointsTests : IntegrationTestBase
{
    private const string ThumbsUp = "\U0001F44D";

    private static readonly string AuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    private sealed record TestDevice(Guid DeviceId, string Token, HttpClient Http);

    /// <summary>Raw body of every response, with the device that received it.</summary>
    private readonly List<(Guid Caller, string Body)> _responses = [];

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private async Task<TestDevice> NewDeviceAsync()
    {
        var http = Factory.CreateClient();
        var reg = await http.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06])
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var regBody = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = regBody.GetProperty("deviceId").GetGuid();

        var tokenResponse = await http.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret = regBody.GetProperty("deviceSecret").GetString()
        });
        tokenResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return new TestDevice(deviceId, token, http);
    }

    /// <summary>Registers an account and links the device to it. Returns the accountId.</summary>
    private async Task<Guid> RegisterAccountAsync(TestDevice device)
    {
        var response = await device.Http.PostAsJsonAsync("/accounts", new
        {
            email = $"channel-test-{Guid.NewGuid():N}@example.com",
            authKey = AuthKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetGuid();
        await LinkAsync(device, accountId);
        return accountId;
    }

    private static async Task LinkAsync(TestDevice device, Guid accountId)
    {
        var link = await device.Http.PostAsJsonAsync(
            $"/accounts/{accountId}/devices/{device.DeviceId}", new { authKey = AuthKey });
        link.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    /// <summary>A device that is allowed to create channels (linked to a fresh account).</summary>
    private async Task<TestDevice> NewOwnerAsync()
    {
        var device = await NewDeviceAsync();
        await RegisterAccountAsync(device);
        return device;
    }

    private async Task<HttpResponseMessage> SendAsync(TestDevice device, HttpMethod method, string url, object? body = null)
    {
        using var request = new HttpRequestMessage(method, url);
        if (body is not null) request.Content = JsonContent.Create(body);
        var response = await device.Http.SendAsync(request);
        // The content is buffered, so reading it here does not stop the test
        // from reading it again afterwards.
        _responses.Add((device.DeviceId, await response.Content.ReadAsStringAsync()));
        return response;
    }

    private static async Task<JsonElement> JsonAsync(HttpResponseMessage response) =>
        await response.Content.ReadFromJsonAsync<JsonElement>();

    private async Task<Guid> CreateChannelAsync(TestDevice owner, string name = "News")
    {
        var response = await SendAsync(owner, HttpMethod.Post, "/channels", new { name, description = "Public updates" });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        return (await JsonAsync(response)).GetProperty("channelId").GetGuid();
    }

    private async Task FollowAsync(TestDevice device, Guid channelId) =>
        (await SendAsync(device, HttpMethod.Post, $"/channels/{channelId}/follow"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

    private Task<HttpResponseMessage> PostTextAsync(TestDevice author, Guid channelId, Guid postId, string text) =>
        SendAsync(author, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId, kind = "text", body = text });

    private HubConnection CreateHubConnection(TestDevice device)
    {
        var server = Factory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={device.Token}", options =>
            {
                options.HttpMessageHandlerFactory = _ => server.CreateHandler();
            })
            .Build();
    }

    /// <summary>Polls until the condition holds; fails the test after 10 s instead of hanging.</summary>
    private static async Task WaitForAsync(Func<bool> condition, string because)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException($"Timed out waiting: {because}");
            await Task.Delay(50);
        }
    }

    private static MultipartFormDataContent ImageContent(int sizeBytes, string contentType = "image/png")
    {
        var file = new ByteArrayContent(Enumerable.Range(0, sizeBytes).Select(i => (byte)i).ToArray());
        file.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        return new MultipartFormDataContent { { file, "file", "picture.png" } };
    }

    private async Task<T> DbAsync<T>(Func<AppDbContext, Task<T>> query)
    {
        using var scope = Factory.Services.CreateScope();
        return await query(scope.ServiceProvider.GetRequiredService<AppDbContext>());
    }

    // -----------------------------------------------------------------------
    // Create — account required (403), owned-channel limit (409)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Anonymous_device_cannot_create_a_channel()
    {
        var anonymous = await NewDeviceAsync();

        var response = await SendAsync(anonymous, HttpMethod.Post, "/channels", new { name = "Nope" });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await JsonAsync(response)).GetProperty("code").GetString().Should().Be("account_required");
        (await DbAsync(db => db.Channels.CountAsync())).Should().Be(0);
    }

    [Fact]
    public async Task Create_returns_handle_and_enforces_owned_channel_limit()
    {
        var owner = await NewOwnerAsync();

        var first = await SendAsync(owner, HttpMethod.Post, "/channels", new { name = "  First  ", description = "d" });
        first.StatusCode.Should().Be(HttpStatusCode.Created);
        var created = await JsonAsync(first);
        created.GetProperty("handle").GetString().Should().MatchRegex("^CH-[A-Z2-9]{4}-[A-Z2-9]{4}$");
        created.GetProperty("name").GetString().Should().Be("First");
        created.GetProperty("role").GetString().Should().Be("owner");
        var firstId = created.GetProperty("channelId").GetGuid();

        // Default Channels:MaxOwnedPerDevice is 5.
        for (var i = 2; i <= 5; i++) await CreateChannelAsync(owner, $"Channel {i}");

        var sixth = await SendAsync(owner, HttpMethod.Post, "/channels", new { name = "Sixth" });
        sixth.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await JsonAsync(sixth)).GetProperty("code").GetString().Should().Be("channel_limit_reached");

        // A deleted channel no longer counts against the limit.
        (await SendAsync(owner, HttpMethod.Delete, $"/channels/{firstId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        await CreateChannelAsync(owner, "Sixth again");

        // ... and is 404 for everyone from now on.
        (await SendAsync(owner, HttpMethod.Get, $"/channels/{firstId}")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Create_rejects_invalid_name()
    {
        var owner = await NewOwnerAsync();

        (await SendAsync(owner, HttpMethod.Post, "/channels", new { name = " " }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await SendAsync(owner, HttpMethod.Post, "/channels", new { name = new string('x', 65) }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await SendAsync(owner, HttpMethod.Post, "/channels", new { description = "no name" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // -----------------------------------------------------------------------
    // Explicit follow, non-follower 403, idempotent follower count
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Channel_is_visible_to_a_device_only_after_explicit_follow()
    {
        var owner = await NewOwnerAsync();
        var reader = await NewDeviceAsync(); // anonymous devices may follow
        var channelId = await CreateChannelAsync(owner);
        await PostTextAsync(owner, channelId, Guid.NewGuid(), "before follow");

        // Not following: nothing in "mine", profile is public, feed is forbidden.
        (await JsonAsync(await SendAsync(reader, HttpMethod.Get, "/channels/mine"))).GetArrayLength().Should().Be(0);
        var profile = await JsonAsync(await SendAsync(reader, HttpMethod.Get, $"/channels/{channelId}"));
        profile.GetProperty("isFollowing").GetBoolean().Should().BeFalse();
        profile.GetProperty("followerCount").GetInt32().Should().Be(0);
        (await SendAsync(reader, HttpMethod.Get, $"/channels/{channelId}/posts"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Follow twice — idempotent, counted once.
        await FollowAsync(reader, channelId);
        await FollowAsync(reader, channelId);

        var mine = await JsonAsync(await SendAsync(reader, HttpMethod.Get, "/channels/mine"));
        mine.GetArrayLength().Should().Be(1);
        mine[0].GetProperty("channelId").GetGuid().Should().Be(channelId);
        mine[0].GetProperty("followerCount").GetInt32().Should().Be(1);
        mine[0].GetProperty("role").ValueKind.Should().Be(JsonValueKind.Null);

        // Lookup by handle (case-insensitive) works too.
        var handle = mine[0].GetProperty("handle").GetString()!;
        var byHandle = await JsonAsync(await SendAsync(reader, HttpMethod.Get, $"/channels/{handle.ToLowerInvariant()}"));
        byHandle.GetProperty("isFollowing").GetBoolean().Should().BeTrue();

        (await SendAsync(reader, HttpMethod.Get, $"/channels/{channelId}/posts"))
            .StatusCode.Should().Be(HttpStatusCode.OK);

        // Unfollow twice — idempotent, never below zero, feed forbidden again.
        for (var i = 0; i < 2; i++)
            (await SendAsync(reader, HttpMethod.Delete, $"/channels/{channelId}/follow"))
                .StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await DbAsync(db => db.Channels.Where(c => c.ChannelId == channelId).Select(c => c.FollowerCount).SingleAsync()))
            .Should().Be(0);
        (await SendAsync(reader, HttpMethod.Get, $"/channels/{channelId}/posts"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Following something that does not exist is a 404, not a silent 204.
        (await SendAsync(reader, HttpMethod.Post, $"/channels/{Guid.NewGuid()}/follow"))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    // -----------------------------------------------------------------------
    // Publishing: roles, idempotence, hub events, tombstones
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Only_owner_or_admin_may_publish()
    {
        var owner = await NewOwnerAsync();
        var follower = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);

        (await PostTextAsync(follower, channelId, Guid.NewGuid(), "I am just a follower"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Promoted to admin -> may publish and delete posts, but not delete the channel.
        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{follower.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        var postId = Guid.NewGuid();
        (await PostTextAsync(follower, channelId, postId, "now I am an admin"))
            .StatusCode.Should().Be(HttpStatusCode.Created);
        (await SendAsync(follower, HttpMethod.Delete, $"/channels/{channelId}"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/admins"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // The owner — and only the owner — sees the admins they appointed.
        var admins = await JsonAsync(await owner.Http.GetAsync($"/channels/{channelId}/admins"));
        admins.EnumerateArray().Select(a => a.GetProperty("deviceId").GetGuid()).Should().Equal(follower.DeviceId);

        // Demoted -> forbidden again.
        (await SendAsync(owner, HttpMethod.Delete, $"/channels/{channelId}/admins/{follower.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await PostTextAsync(follower, channelId, Guid.NewGuid(), "demoted"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Request validation.
        (await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId = Guid.NewGuid(), kind = "video", body = "x" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId = Guid.NewGuid(), kind = "text", body = " " }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId = Guid.NewGuid(), kind = "poll", body = "{\"question\":\"Q\",\"options\":[\"only one\"]}" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Repeated_post_is_stored_once_and_broadcast_once_and_delete_sends_tombstone()
    {
        var owner = await NewOwnerAsync();
        var follower = await NewDeviceAsync();
        var stranger = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);

        var followerEvents = new ConcurrentQueue<JsonElement>();
        var strangerEvents = new ConcurrentQueue<JsonElement>();
        var deletedChannels = new ConcurrentQueue<JsonElement>();

        await using var followerHub = CreateHubConnection(follower);
        followerHub.On<JsonElement>("ReceiveChannelPost", followerEvents.Enqueue);
        followerHub.On<JsonElement>("ChannelDeleted", deletedChannels.Enqueue);
        await followerHub.StartAsync();
        (await followerHub.InvokeAsync<List<Guid>>("JoinChannels")).Should().Equal(channelId);

        await using var strangerHub = CreateHubConnection(stranger);
        strangerHub.On<JsonElement>("ReceiveChannelPost", strangerEvents.Enqueue);
        await strangerHub.StartAsync();
        (await strangerHub.InvokeAsync<List<Guid>>("JoinChannels")).Should().BeEmpty();

        // Same postId twice: 201 then 200, the retry's different text is ignored.
        var postId = Guid.NewGuid();
        var first = await PostTextAsync(owner, channelId, postId, "hello");
        first.StatusCode.Should().Be(HttpStatusCode.Created);
        var retry = await PostTextAsync(owner, channelId, postId, "hello (retry)");
        retry.StatusCode.Should().Be(HttpStatusCode.OK);
        (await JsonAsync(retry)).GetProperty("body").GetString().Should().Be("hello");

        // A second, different post acts as a barrier: once it has arrived, a
        // duplicate event for the first post would have arrived before it.
        var secondId = Guid.NewGuid();
        (await PostTextAsync(owner, channelId, secondId, "second")).StatusCode.Should().Be(HttpStatusCode.Created);
        await WaitForAsync(() => followerEvents.Any(e => e.GetProperty("postId").GetGuid() == secondId), "second post event");

        (await DbAsync(db => db.ChannelPosts.CountAsync(p => p.PostId == postId))).Should().Be(1);
        followerEvents.Count(e => e.GetProperty("postId").GetGuid() == postId).Should().Be(1);

        var postEvent = followerEvents.First(e => e.GetProperty("postId").GetGuid() == postId);
        postEvent.GetProperty("channelId").GetGuid().Should().Be(channelId);
        postEvent.GetProperty("kind").GetString().Should().Be("text");
        postEvent.GetProperty("body").GetString().Should().Be("hello");
        postEvent.GetProperty("attachmentBlobPath").ValueKind.Should().Be(JsonValueKind.Null);
        postEvent.GetProperty("deleted").GetBoolean().Should().BeFalse();
        postEvent.GetProperty("createdAt").GetDateTimeOffset()
            .Should().Be((await JsonAsync(first)).GetProperty("createdAt").GetDateTimeOffset());

        // The same postId in ANOTHER channel is a conflict, not a retry.
        var otherChannel = await CreateChannelAsync(owner, "Other");
        (await PostTextAsync(owner, otherChannel, postId, "hijack")).StatusCode.Should().Be(HttpStatusCode.Conflict);

        // Soft delete -> tombstone event with blanked content, tombstone in the feed.
        (await SendAsync(owner, HttpMethod.Delete, $"/channels/{channelId}/posts/{postId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        await WaitForAsync(() => followerEvents.Any(e => e.GetProperty("deleted").GetBoolean()), "tombstone event");
        var tombstone = followerEvents.Single(e => e.GetProperty("deleted").GetBoolean());
        tombstone.GetProperty("postId").GetGuid().Should().Be(postId);
        tombstone.GetProperty("body").GetString().Should().BeEmpty();

        var feed = await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts"));
        var deletedInFeed = feed.EnumerateArray().Single(p => p.GetProperty("postId").GetGuid() == postId);
        deletedInFeed.GetProperty("deleted").GetBoolean().Should().BeTrue();
        deletedInFeed.GetProperty("body").GetString().Should().BeEmpty();
        (await DbAsync(db => db.ChannelPosts.Where(p => p.PostId == postId).Select(p => p.DeletedAt).SingleAsync()))
            .Should().NotBeNull("soft delete keeps the row");

        // Deleting twice: the post is already gone.
        (await SendAsync(owner, HttpMethod.Delete, $"/channels/{channelId}/posts/{postId}"))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);

        // LeaveChannel stops delivery; the channel tombstone reaches who is still joined.
        await using var secondFollowerHub = CreateHubConnection(follower);
        var leftEvents = new ConcurrentQueue<JsonElement>();
        secondFollowerHub.On<JsonElement>("ReceiveChannelPost", leftEvents.Enqueue);
        await secondFollowerHub.StartAsync();
        await secondFollowerHub.InvokeAsync<List<Guid>>("JoinChannels");
        await secondFollowerHub.InvokeAsync("LeaveChannel", channelId);

        var thirdId = Guid.NewGuid();
        await PostTextAsync(owner, channelId, thirdId, "third");
        await WaitForAsync(() => followerEvents.Any(e => e.GetProperty("postId").GetGuid() == thirdId), "third post event");
        leftEvents.Should().BeEmpty("that connection left the channel group");

        (await SendAsync(owner, HttpMethod.Delete, $"/channels/{channelId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        await WaitForAsync(() => !deletedChannels.IsEmpty, "ChannelDeleted event");
        deletedChannels.Single().GetProperty("channelId").GetGuid().Should().Be(channelId);

        strangerEvents.Should().BeEmpty("a device that follows nothing must not receive channel posts");
    }

    // -----------------------------------------------------------------------
    // Feed paging (before / after) and unread count
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Feed_pages_with_before_and_after_and_reading_clears_unread()
    {
        var owner = await NewOwnerAsync();
        var follower = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);

        var created = new List<DateTimeOffset>();
        for (var i = 1; i <= 3; i++)
        {
            var response = await PostTextAsync(owner, channelId, Guid.NewGuid(), $"post {i}");
            created.Add((await JsonAsync(response)).GetProperty("createdAt").GetDateTimeOffset());
        }

        async Task<List<string?>> BodiesAsync(string query) =>
            (await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts{query}")))
                .EnumerateArray().Select(p => p.GetProperty("body").GetString()).ToList();

        static string Ts(DateTimeOffset value) => Uri.EscapeDataString(value.ToString("O"));

        var mine = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/mine"));
        mine[0].GetProperty("unreadCount").GetInt32().Should().Be(3);

        // "after" = catch-up: the OLDEST posts after the cursor, still newest first.
        (await BodiesAsync($"?after={Ts(created[0])}&limit=1")).Should().Equal("post 2");
        mine = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/mine"));
        mine[0].GetProperty("unreadCount").GetInt32().Should().Be(1, "post 3 has not been fetched yet");

        (await BodiesAsync($"?after={Ts(created[0])}")).Should().Equal("post 3", "post 2");
        (await BodiesAsync($"?before={Ts(created[2])}")).Should().Equal("post 2", "post 1");
        (await BodiesAsync("?limit=2")).Should().Equal("post 3", "post 2");

        mine = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/mine"));
        mine[0].GetProperty("unreadCount").GetInt32().Should().Be(0);

        // The owner sees the channel in "mine" without following it.
        var ownerMine = await JsonAsync(await SendAsync(owner, HttpMethod.Get, "/channels/mine"));
        ownerMine[0].GetProperty("role").GetString().Should().Be("owner");
        ownerMine[0].GetProperty("isFollowing").GetBoolean().Should().BeFalse();
    }

    // -----------------------------------------------------------------------
    // Attachments: 413, type whitelist, access control
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Oversized_image_is_rejected_and_valid_image_is_served_to_followers_only()
    {
        var owner = await NewOwnerAsync();
        var follower = await NewDeviceAsync();
        var stranger = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);

        // Default Channels:MaxImageBytes is 2 MiB.
        using var tooBig = ImageContent(2 * 1024 * 1024 + 1);
        (await owner.Http.PostAsync($"/channels/{channelId}/attachments", tooBig))
            .StatusCode.Should().Be(HttpStatusCode.RequestEntityTooLarge);

        using var notAnImage = ImageContent(10, "text/html");
        (await owner.Http.PostAsync($"/channels/{channelId}/attachments", notAnImage))
            .StatusCode.Should().Be(HttpStatusCode.UnsupportedMediaType);

        using var byFollower = ImageContent(10);
        (await follower.Http.PostAsync($"/channels/{channelId}/attachments", byFollower))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        using var image = ImageContent(1024);
        var upload = await owner.Http.PostAsync($"/channels/{channelId}/attachments", image);
        upload.StatusCode.Should().Be(HttpStatusCode.Created);
        var uploaded = await JsonAsync(upload);
        var blobPath = uploaded.GetProperty("blobPath").GetString()!;
        var name = uploaded.GetProperty("name").GetString()!;
        blobPath.Should().Be($"channel-media/{channelId}/{name}");

        // Image post must reference an attachment of THIS channel.
        (await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts",
                new { postId = Guid.NewGuid(), kind = "image", body = "", attachmentBlobPath = $"channel-media/{Guid.NewGuid()}/{name}" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts",
                new { postId = Guid.NewGuid(), kind = "text", body = "x", attachmentBlobPath = blobPath }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        var post = await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts",
            new { postId = Guid.NewGuid(), kind = "image", body = "caption", attachmentBlobPath = blobPath });
        post.StatusCode.Should().Be(HttpStatusCode.Created);
        (await JsonAsync(post)).GetProperty("attachmentBlobPath").GetString().Should().Be(blobPath);

        var download = await follower.Http.GetAsync($"/channels/{channelId}/attachments/{name}");
        download.StatusCode.Should().Be(HttpStatusCode.OK);
        download.Content.Headers.ContentType!.MediaType.Should().Be("image/png");
        (await download.Content.ReadAsByteArrayAsync()).Should().HaveCount(1024);

        (await stranger.Http.GetAsync($"/channels/{channelId}/attachments/{name}"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await follower.Http.GetAsync($"/channels/{channelId}/attachments/{Guid.NewGuid():N}.png"))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    // -----------------------------------------------------------------------
    // Reactions and polls: 422, one per device, totals only
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Reactions_and_votes_are_validated_and_returned_as_totals()
    {
        var owner = await NewOwnerAsync();
        var first = await NewDeviceAsync();
        var second = await NewDeviceAsync();
        var stranger = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(first, channelId);
        await FollowAsync(second, channelId);

        var textId = Guid.NewGuid();
        await PostTextAsync(owner, channelId, textId, "react to me");
        var pollId = Guid.NewGuid();
        // Poll body sent as a JSON object; a string containing the same JSON is
        // covered in Only_owner_or_admin_may_publish.
        (await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts", new
        {
            postId = pollId,
            kind = "poll",
            body = new { question = "Lunch?", options = new[] { "Pizza", "Soup" } }
        })).StatusCode.Should().Be(HttpStatusCode.Created);

        var reactionUrl = $"/channels/{channelId}/posts/{textId}/reaction";
        var voteUrl = $"/channels/{channelId}/posts/{pollId}/vote";

        // 422: emoji outside the whitelist, option index out of range, vote on a non-poll.
        (await SendAsync(first, HttpMethod.Put, reactionUrl, new { emoji = "\U0001F4A9" }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await SendAsync(first, HttpMethod.Put, voteUrl, new { optionIndex = 2 }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await SendAsync(first, HttpMethod.Put, voteUrl, new { optionIndex = -1 }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await SendAsync(first, HttpMethod.Put, $"/channels/{channelId}/posts/{textId}/vote", new { optionIndex = 0 }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        // 403 for a non-follower, 404 for an unknown post.
        (await SendAsync(stranger, HttpMethod.Put, reactionUrl, new { emoji = ThumbsUp }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(first, HttpMethod.Put, $"/channels/{channelId}/posts/{Guid.NewGuid()}/reaction", new { emoji = ThumbsUp }))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);

        // One reaction per device: reacting again replaces, it does not add.
        await SendAsync(first, HttpMethod.Put, reactionUrl, new { emoji = "❤" });
        await SendAsync(first, HttpMethod.Put, reactionUrl, new { emoji = ThumbsUp });
        var afterSecond = await JsonAsync(await SendAsync(second, HttpMethod.Put, reactionUrl, new { emoji = ThumbsUp }));
        afterSecond.GetProperty("reactions").GetProperty(ThumbsUp).GetInt32().Should().Be(2);
        afterSecond.GetProperty("reactions").EnumerateObject().Should().HaveCount(1);
        afterSecond.GetProperty("myReaction").GetString().Should().Be(ThumbsUp);

        // One vote per device; changing it moves the vote.
        await SendAsync(first, HttpMethod.Put, voteUrl, new { optionIndex = 0 });
        var changed = await JsonAsync(await SendAsync(first, HttpMethod.Put, voteUrl, new { optionIndex = 1 }));
        changed.GetProperty("votes").EnumerateObject().Should().HaveCount(1);
        changed.GetProperty("votes").GetProperty("1").GetInt32().Should().Be(1);
        changed.GetProperty("myVote").GetInt32().Should().Be(1);

        // Removing a reaction is idempotent.
        for (var i = 0; i < 2; i++)
            (await SendAsync(second, HttpMethod.Delete, reactionUrl)).StatusCode.Should().Be(HttpStatusCode.OK);

        // The feed carries the same totals plus the CALLER'S own choice only.
        var feed = await JsonAsync(await SendAsync(second, HttpMethod.Get, $"/channels/{channelId}/posts"));
        var text = feed.EnumerateArray().Single(p => p.GetProperty("postId").GetGuid() == textId);
        text.GetProperty("reactions").GetProperty(ThumbsUp).GetInt32().Should().Be(1);
        text.GetProperty("myReaction").ValueKind.Should().Be(JsonValueKind.Null);
        var poll = feed.EnumerateArray().Single(p => p.GetProperty("postId").GetGuid() == pollId);
        poll.GetProperty("votes").GetProperty("1").GetInt32().Should().Be(1);
        poll.GetProperty("myVote").ValueKind.Should().Be(JsonValueKind.Null);
        JsonDocument.Parse(poll.GetProperty("body").GetString()!).RootElement
            .GetProperty("options").GetArrayLength().Should().Be(2);
    }

    // -----------------------------------------------------------------------
    // Report
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Report_creates_a_row_and_never_exposes_the_reporter()
    {
        var owner = await NewOwnerAsync();
        var reporter = await NewDeviceAsync();
        var stranger = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(reporter, channelId);
        var postId = Guid.NewGuid();
        await PostTextAsync(owner, channelId, postId, "questionable");

        (await SendAsync(stranger, HttpMethod.Post, $"/channels/{channelId}/report", new { reason = "spam" }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", new { reason = " " }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", new { postId = Guid.NewGuid(), reason = "spam" }))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);

        // Moderation contract 3: the answer is now a 200 receipt, not 204.
        var response = await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", new { postId, reason = "spam" });
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var report = await DbAsync(db => db.ChannelReports.SingleAsync());
        report.ChannelId.Should().Be(channelId);
        report.PostId.Should().Be(postId);
        report.ReporterDeviceId.Should().Be(reporter.DeviceId);
        report.Reason.Should().Be("spam");

        // Whole-channel report (no postId) works too; then the daily budget runs out.
        for (var i = 2; i <= 5; i++)
            (await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", new { reason = $"spam {i}" }))
                .StatusCode.Should().Be(HttpStatusCode.OK);
        (await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", new { reason = "one too many" }))
            .StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        (await DbAsync(db => db.ChannelReports.CountAsync())).Should().Be(5);

        // Nothing the owner can fetch afterwards mentions the reporter.
        await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}");
        await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/posts");
        await SendAsync(owner, HttpMethod.Get, "/channels/mine");
        _responses.Where(r => r.Caller == owner.DeviceId)
            .Should().NotContain(r => r.Body.Contains(reporter.DeviceId.ToString(), StringComparison.OrdinalIgnoreCase));
    }

    // -----------------------------------------------------------------------
    // Ownership through the account (plan §7.4)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Second_device_of_the_owner_account_has_owner_rights()
    {
        var firstDevice = await NewDeviceAsync();
        var accountId = await RegisterAccountAsync(firstDevice);
        var channelId = await CreateChannelAsync(firstDevice);

        var secondDevice = await NewDeviceAsync();
        (await SendAsync(secondDevice, HttpMethod.Patch, $"/channels/{channelId}", new { name = "Hacked" }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden, "not linked to the owner account yet");

        await LinkAsync(secondDevice, accountId);

        var profile = await JsonAsync(await SendAsync(secondDevice, HttpMethod.Get, $"/channels/{channelId}"));
        profile.GetProperty("role").GetString().Should().Be("owner");

        var patched = await SendAsync(secondDevice, HttpMethod.Patch, $"/channels/{channelId}", new { name = "Renamed" });
        patched.StatusCode.Should().Be(HttpStatusCode.OK);
        var patchedBody = await JsonAsync(patched);
        patchedBody.GetProperty("name").GetString().Should().Be("Renamed");
        patchedBody.GetProperty("description").GetString().Should().Be("Public updates", "absent property = unchanged");

        (await PostTextAsync(secondDevice, channelId, Guid.NewGuid(), "from my new phone"))
            .StatusCode.Should().Be(HttpStatusCode.Created);

        // Owner-only operations: manage admins, delete the channel.
        var helper = await NewDeviceAsync();
        (await SendAsync(secondDevice, HttpMethod.Put, $"/channels/{channelId}/admins/{helper.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await SendAsync(secondDevice, HttpMethod.Put, $"/channels/{channelId}/admins/{Guid.NewGuid()}"))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);

        // The owned-channel limit is shared by the account, not per device.
        for (var i = 2; i <= 5; i++) await CreateChannelAsync(secondDevice, $"Channel {i}");
        (await SendAsync(firstDevice, HttpMethod.Post, "/channels", new { name = "Sixth" }))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);

        (await SendAsync(secondDevice, HttpMethod.Delete, $"/channels/{channelId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
    }

    // -----------------------------------------------------------------------
    // Anonymity scan (plan §6): no foreign DeviceId in any response or event
    // -----------------------------------------------------------------------

    [Fact]
    public async Task No_response_or_hub_event_contains_a_foreign_device_id()
    {
        var owner = await NewDeviceAsync();
        var accountId = await RegisterAccountAsync(owner);
        var admin = await NewDeviceAsync();
        var followerB = await NewDeviceAsync();
        var followerC = await NewDeviceAsync();
        var everyone = new[] { owner, admin, followerB, followerC };

        var channelId = await CreateChannelAsync(owner);
        await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{admin.DeviceId}");
        await FollowAsync(followerB, channelId);
        await FollowAsync(followerC, channelId);

        // Everybody listens on the hub; payloads are kept as raw JSON text.
        var hubPayloads = new ConcurrentQueue<string>();
        var hubs = new List<HubConnection>();
        foreach (var device in everyone)
        {
            var hub = CreateHubConnection(device);
            hub.On<JsonElement>("ReceiveChannelPost", e => hubPayloads.Enqueue(e.GetRawText()));
            hub.On<JsonElement>("ChannelDeleted", e => hubPayloads.Enqueue(e.GetRawText()));
            await hub.StartAsync();
            hubPayloads.Enqueue(JsonSerializer.Serialize(await hub.InvokeAsync<List<Guid>>("JoinChannels")));
            hubs.Add(hub);
        }

        try
        {
            var textId = Guid.NewGuid();
            await PostTextAsync(owner, channelId, textId, "hello followers");
            var pollId = Guid.NewGuid();
            await SendAsync(admin, HttpMethod.Post, $"/channels/{channelId}/posts", new
            {
                postId = pollId, kind = "poll", body = "{\"question\":\"Q\",\"options\":[\"a\",\"b\"]}"
            });

            await SendAsync(followerB, HttpMethod.Put, $"/channels/{channelId}/posts/{textId}/reaction", new { emoji = ThumbsUp });
            await SendAsync(followerC, HttpMethod.Put, $"/channels/{channelId}/posts/{textId}/reaction", new { emoji = ThumbsUp });
            await SendAsync(followerC, HttpMethod.Put, $"/channels/{channelId}/posts/{pollId}/vote", new { optionIndex = 1 });
            await SendAsync(followerB, HttpMethod.Put, $"/channels/{channelId}/posts/{pollId}/vote", new { optionIndex = 0 });
            await SendAsync(followerB, HttpMethod.Post, $"/channels/{channelId}/report", new { postId = textId, reason = "test" });

            foreach (var device in everyone)
            {
                await SendAsync(device, HttpMethod.Get, $"/channels/{channelId}");
                await SendAsync(device, HttpMethod.Get, "/channels/mine");
                await SendAsync(device, HttpMethod.Get, $"/channels/{channelId}/posts");
            }

            await SendAsync(admin, HttpMethod.Delete, $"/channels/{channelId}/posts/{textId}");
            await SendAsync(owner, HttpMethod.Patch, $"/channels/{channelId}", new { description = "edited" });
            await SendAsync(followerC, HttpMethod.Delete, $"/channels/{channelId}/follow");
            await SendAsync(owner, HttpMethod.Delete, $"/channels/{channelId}");

            // 4 connections x (2 posts + 1 tombstone + ChannelDeleted) + 4 JoinChannels results.
            await WaitForAsync(() => hubPayloads.Count >= 20, "all hub events delivered");
        }
        finally
        {
            foreach (var hub in hubs) await hub.DisposeAsync();
        }

        _responses.Should().HaveCountGreaterThan(20, "the scan must actually have something to scan");

        // A response may mention the caller's own id, never anybody else's —
        // and never the owner's account id.
        foreach (var (caller, body) in _responses)
        {
            foreach (var other in everyone.Where(d => d.DeviceId != caller))
                body.Should().NotContain(other.DeviceId.ToString(), $"response to {caller} leaks a foreign device id");
            body.Should().NotContain(accountId.ToString());
        }

        // Hub payloads are broadcast, so they must not contain ANY device id.
        foreach (var payload in hubPayloads)
            foreach (var device in everyone)
                payload.Should().NotContain(device.DeviceId.ToString());

        // Positive control: the totals really were in those responses.
        _responses.Should().Contain(r => r.Body.Contains("\"followerCount\":2"));
    }
}
