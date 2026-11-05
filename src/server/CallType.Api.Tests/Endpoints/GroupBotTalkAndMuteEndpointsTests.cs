// ---------------------------------------------------------------------------
// GroupBotTalkAndMuteEndpointsTests.cs - bot conversations contract (server)
// ---------------------------------------------------------------------------
// Covers PUT /groups/{id}/bot-talk (admin gate, validation, prune on member
// removal, GroupChanged hint), the botTalk/myMute fields of GET /groups/{id}
// and the mute endpoints. Push skipping is in Hubs/MutePushTests.cs.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class GroupBotTalkAndMuteEndpointsTests : IntegrationTestBase
{
    private HttpClient As(string token)
    {
        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>Registers a device without touching the shared Client's auth header.</summary>
    private async Task<(Guid Id, HttpClient Http, string Token)> DeviceAsync(bool isBot = false)
    {
        var reg = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]),
            isBot
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var id = Guid.Parse(body.GetProperty("deviceId").GetString()!);
        var tokenResponse = await Client.PostAsJsonAsync("/auth/token",
            new { deviceId = id, deviceSecret = body.GetProperty("deviceSecret").GetString() });
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
        return (id, As(token), token);
    }

    private static async Task<Guid> CreateGroupAsync(HttpClient admin, params Guid[] members)
    {
        var response = await admin.PostAsJsonAsync("/groups", new { memberDeviceIds = members });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();
    }

    private async Task LinkAsync(Guid primary, Guid companion)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.DeviceLists.Add(new DeviceList
        {
            PrimaryDeviceId = primary, Version = 1, Payload = [1], Signature = new byte[64],
            UpdatedAt = DateTimeOffset.UtcNow,
            Members = [new DeviceListMember { DeviceId = companion, PrimaryDeviceId = primary }]
        });
        await db.SaveChangesAsync();
    }

    private static object Setting(string mode, Guid[]? ids = null, int turns = 5, int pause = 30) =>
        new { mode, allowedBotDeviceIds = ids ?? [], maxBotTurns = turns, pauseMinutes = pause };

    [Fact]
    public async Task New_group_reports_default_bot_talk_and_no_mute()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);

        var info = await admin.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}");

        var botTalk = info.GetProperty("botTalk");
        botTalk.GetProperty("mode").GetString().Should().Be("off");
        botTalk.GetProperty("allowedBotDeviceIds").GetArrayLength().Should().Be(0);
        botTalk.GetProperty("maxBotTurns").GetInt32().Should().Be(5);
        botTalk.GetProperty("pauseMinutes").GetInt32().Should().Be(30);
        botTalk.GetProperty("updatedAt").ValueKind.Should().Be(JsonValueKind.Null);
        info.GetProperty("myMute").GetProperty("mode").GetString().Should().Be("off");
        info.GetProperty("myMute").GetProperty("until").ValueKind.Should().Be(JsonValueKind.Null);
    }

    [Fact]
    public async Task Admin_sets_selected_bots_and_every_member_reads_it()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var botA = await DeviceAsync(isBot: true);
        var botB = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, member.Id, botA.Id, botB.Id);

        var response = await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk",
            Setting("selected", [botA.Id, botB.Id, botA.Id], turns: 7, pause: 0));

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("mode").GetString().Should().Be("selected");
        body.GetProperty("allowedBotDeviceIds").EnumerateArray().Select(e => e.GetGuid())
            .Should().BeEquivalentTo(new[] { botA.Id, botB.Id });
        body.GetProperty("maxBotTurns").GetInt32().Should().Be(7);
        // 0 is a legal pause and must survive the round trip (not replaced by the DB default).
        body.GetProperty("pauseMinutes").GetInt32().Should().Be(0);
        body.GetProperty("updatedAt").GetDateTimeOffset().Should().BeCloseTo(DateTimeOffset.UtcNow, TimeSpan.FromMinutes(1));

        var seen = (await member.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("botTalk");
        seen.GetProperty("mode").GetString().Should().Be("selected");
        seen.GetProperty("allowedBotDeviceIds").GetArrayLength().Should().Be(2);
        seen.GetProperty("pauseMinutes").GetInt32().Should().Be(0);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Groups.AsNoTracking().SingleAsync(g => g.GroupId == group)).BotTalk.UpdatedBy.Should().Be(admin.Id);
    }

    [Fact]
    public async Task Omitted_numbers_keep_their_current_values()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);
        (await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk", Setting("all", turns: 9, pause: 60)))
            .StatusCode.Should().Be(HttpStatusCode.OK);

        var response = await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk", new { mode = "off" });

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("mode").GetString().Should().Be("off");
        body.GetProperty("maxBotTurns").GetInt32().Should().Be(9);
        body.GetProperty("pauseMinutes").GetInt32().Should().Be(60);
    }

    [Fact]
    public async Task Only_admins_may_change_bot_talk_with_the_add_member_status_codes()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var outsider = await DeviceAsync();
        var adminWeb = await DeviceAsync();
        await LinkAsync(admin.Id, adminWeb.Id);
        var group = await CreateGroupAsync(admin.Http, member.Id);

        // Same gate as PUT /groups/{id}/members, compared side by side.
        foreach (var (who, expected) in new[] {
                     (member.Http, HttpStatusCode.Forbidden),
                     (outsider.Http, HttpStatusCode.Forbidden),
                     // Membership changes stay with the member device itself, so does this.
                     (adminWeb.Http, HttpStatusCode.Forbidden) })
        {
            (await who.PutAsJsonAsync($"/groups/{group}/bot-talk", Setting("all"))).StatusCode.Should().Be(expected);
            (await who.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = outsider.Id })).StatusCode.Should().Be(expected);
        }
        (await admin.Http.PutAsJsonAsync($"/groups/{Guid.NewGuid()}/bot-talk", Setting("all")))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await Client.PutAsJsonAsync($"/groups/{group}/bot-talk", Setting("all")))
            .StatusCode.Should().Be(HttpStatusCode.Unauthorized);

        var botTalk = (await member.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("botTalk");
        botTalk.GetProperty("mode").GetString().Should().Be("off");
    }

    public static TheoryData<string, string> InvalidSettings => new()
    {
        { """{"mode":"sometimes"}""", "invalid_mode" },
        { """{"maxBotTurns":5}""", "invalid_mode" },
        { """{"mode":"all","maxBotTurns":0}""", "invalid_max_bot_turns" },
        { """{"mode":"all","maxBotTurns":51}""", "invalid_max_bot_turns" },
        { """{"mode":"all","pauseMinutes":-1}""", "invalid_pause_minutes" },
        { """{"mode":"all","pauseMinutes":1441}""", "invalid_pause_minutes" },
    };

    [Theory]
    [MemberData(nameof(InvalidSettings))]
    public async Task Invalid_setting_is_a_400_problem(string json, string error)
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);

        var response = await admin.Http.PutAsync($"/groups/{group}/bot-talk",
            new StringContent(json, System.Text.Encoding.UTF8, "application/json"));

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        response.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString().Should().Be(error);
    }

    [Fact]
    public async Task Allowed_ids_must_be_current_bot_members()
    {
        var admin = await DeviceAsync();
        var human = await DeviceAsync();
        var botMember = await DeviceAsync(isBot: true);
        var botOutsider = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, human.Id, botMember.Id);

        foreach (var bad in new[] { human.Id, botOutsider.Id, Guid.NewGuid(), admin.Id })
        {
            var response = await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk",
                Setting("selected", [botMember.Id, bad]));
            response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
                .Should().Be("not_a_bot_member");
        }
        (await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk", Setting("selected", [botMember.Id])))
            .StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Removing_a_member_prunes_it_from_the_allowed_list()
    {
        var admin = await DeviceAsync();
        var botA = await DeviceAsync(isBot: true);
        var botB = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, botA.Id, botB.Id);
        (await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk", Setting("selected", [botA.Id, botB.Id])))
            .StatusCode.Should().Be(HttpStatusCode.OK);

        (await admin.Http.DeleteAsync($"/groups/{group}/members/{botA.Id}")).StatusCode.Should().Be(HttpStatusCode.OK);

        var botTalk = (await admin.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("botTalk");
        botTalk.GetProperty("allowedBotDeviceIds").EnumerateArray().Select(e => e.GetGuid())
            .Should().Equal(botB.Id);
        // Pruned in storage, not only hidden on read: re-adding the bot must not
        // silently make it allowed again.
        (await admin.Http.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = botA.Id }))
            .StatusCode.Should().Be(HttpStatusCode.OK);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Groups.AsNoTracking().SingleAsync(g => g.GroupId == group)).BotTalk.AllowedBotDeviceIds
            .Should().Equal(botB.Id);
    }

    [Fact]
    public async Task Bot_talk_change_sends_GroupChanged_to_members_and_their_companions()
    {
        var admin = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var phone = await DeviceAsync();
        var web = await DeviceAsync();
        await LinkAsync(phone.Id, web.Id);
        var group = await CreateGroupAsync(admin.Http, bot.Id, phone.Id);

        async Task<(HubConnection Hub, TaskCompletionSource<JsonElement> Hint)> ListenAsync(string token)
        {
            var hub = new HubConnectionBuilder()
                .WithUrl($"{Factory.Server.BaseAddress}hub?access_token={token}",
                    o => o.HttpMessageHandlerFactory = _ => Factory.Server.CreateHandler())
                .Build();
            var hint = new TaskCompletionSource<JsonElement>();
            hub.On<JsonElement>("GroupChanged", e => hint.TrySetResult(e));
            await hub.StartAsync();
            return (hub, hint);
        }
        var (botHub, botHint) = await ListenAsync(bot.Token);
        var (webHub, webHint) = await ListenAsync(web.Token);
        await using var _ = botHub;
        await using var __ = webHub;

        (await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk", Setting("all")))
            .StatusCode.Should().Be(HttpStatusCode.OK);

        (await botHint.Task.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("groupId").GetGuid().Should().Be(group);
        (await webHint.Task.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("groupId").GetGuid().Should().Be(group);
    }

    [Fact]
    public async Task Removed_member_hears_GroupChanged_too()
    {
        var admin = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, bot.Id);
        await using var hub = new HubConnectionBuilder()
            .WithUrl($"{Factory.Server.BaseAddress}hub?access_token={bot.Token}",
                o => o.HttpMessageHandlerFactory = _ => Factory.Server.CreateHandler())
            .Build();
        var hint = new TaskCompletionSource<JsonElement>();
        hub.On<JsonElement>("GroupChanged", e => hint.TrySetResult(e));
        await hub.StartAsync();

        (await admin.Http.DeleteAsync($"/groups/{group}/members/{bot.Id}")).StatusCode.Should().Be(HttpStatusCode.OK);

        (await hint.Task.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("groupId").GetGuid().Should().Be(group);
    }

    // -----------------------------------------------------------------------
    // Mutes
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Group_mute_is_per_device_and_shows_up_in_GET_group_and_GET_mutes()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http, member.Id);
        var until = DateTimeOffset.UtcNow.AddHours(2);

        (await member.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "bots", until }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var myMute = (await member.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("myMute");
        myMute.GetProperty("mode").GetString().Should().Be("bots");
        myMute.GetProperty("until").GetDateTimeOffset().Should().BeCloseTo(until, TimeSpan.FromMilliseconds(1));
        // Another device of the group sees its OWN mute, not the member's.
        (await admin.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("myMute")
            .GetProperty("mode").GetString().Should().Be("off");

        var list = await member.Http.GetFromJsonAsync<JsonElement>("/mutes");
        var item = list.EnumerateArray().Single();
        item.GetProperty("groupId").GetGuid().Should().Be(group);
        item.GetProperty("peerDeviceId").ValueKind.Should().Be(JsonValueKind.Null);
        item.GetProperty("mode").GetString().Should().Be("bots");
        (await admin.Http.GetFromJsonAsync<JsonElement>("/mutes")).GetArrayLength().Should().Be(0);

        // Upsert, then "off" removes it.
        (await member.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "all", until = (DateTimeOffset?)null }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await member.Http.GetFromJsonAsync<JsonElement>("/mutes")).EnumerateArray().Single()
            .GetProperty("mode").GetString().Should().Be("all");
        (await member.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "off" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await member.Http.GetFromJsonAsync<JsonElement>("/mutes")).GetArrayLength().Should().Be(0);
    }

    [Fact]
    public async Task Expired_mute_reads_as_off()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);

        (await admin.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "all", until = DateTimeOffset.UtcNow.AddMinutes(-1) }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await admin.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("myMute")
            .GetProperty("mode").GetString().Should().Be("off");
        (await admin.Http.GetFromJsonAsync<JsonElement>("/mutes")).GetArrayLength().Should().Be(0);
    }

    [Fact]
    public async Task Group_mute_is_member_gated_and_validated()
    {
        var admin = await DeviceAsync();
        var outsider = await DeviceAsync();
        var adminWeb = await DeviceAsync();
        await LinkAsync(admin.Id, adminWeb.Id);
        var group = await CreateGroupAsync(admin.Http);

        (await outsider.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await admin.Http.PutAsJsonAsync($"/groups/{Guid.NewGuid()}/mute", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
        var invalid = await admin.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "loud" });
        invalid.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        invalid.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        (await Client.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        // A companion receives the group's messages, so it may mute it (for itself).
        (await adminWeb.Http.PutAsJsonAsync($"/groups/{group}/mute", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await admin.Http.GetFromJsonAsync<JsonElement>("/mutes")).GetArrayLength().Should().Be(0);
    }

    [Fact]
    public async Task Direct_mute_resolves_the_peer_to_its_primary_device()
    {
        var me = await DeviceAsync();
        var alicePhone = await DeviceAsync();
        var aliceWeb = await DeviceAsync();
        await LinkAsync(alicePhone.Id, aliceWeb.Id);

        (await me.Http.PutAsJsonAsync($"/mutes/direct/{aliceWeb.Id}", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        // Muting via the primary hits the same row (upsert, not a second mute).
        (await me.Http.PutAsJsonAsync($"/mutes/direct/{alicePhone.Id}", new { mode = "bots" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var item = (await me.Http.GetFromJsonAsync<JsonElement>("/mutes")).EnumerateArray().Single();
        item.GetProperty("peerDeviceId").GetGuid().Should().Be(alicePhone.Id);
        item.GetProperty("groupId").ValueKind.Should().Be(JsonValueKind.Null);
        item.GetProperty("mode").GetString().Should().Be("bots");
        item.GetProperty("until").ValueKind.Should().Be(JsonValueKind.Null);
    }

    [Fact]
    public async Task Direct_mute_rejects_unknown_peer_bad_mode_and_own_identity()
    {
        var me = await DeviceAsync();
        var myWeb = await DeviceAsync();
        var peer = await DeviceAsync();
        await LinkAsync(me.Id, myWeb.Id);

        (await me.Http.PutAsJsonAsync($"/mutes/direct/{Guid.NewGuid()}", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await me.Http.PutAsJsonAsync($"/mutes/direct/{peer.Id}", new { mode = "silent" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await me.Http.PutAsJsonAsync($"/mutes/direct/{myWeb.Id}", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await Client.GetAsync("/mutes")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }
}
