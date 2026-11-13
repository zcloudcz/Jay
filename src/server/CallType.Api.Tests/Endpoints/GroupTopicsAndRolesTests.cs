// ---------------------------------------------------------------------------
// GroupTopicsAndRolesTests.cs - group topics contract (server rows S1-S4)
// ---------------------------------------------------------------------------
// Spec docs/superpowers/specs/2026-11-13-group-topics.md: member role endpoint
// (S1), topic version record (S2), the additive GET /groups/{id} fields (S3)
// and the two new bot-talk flags (S4). The topic text itself is E2E and never
// reaches the server, so only the record is tested here.
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

public class GroupTopicsAndRolesTests : IntegrationTestBase
{
    private HttpClient As(string token)
    {
        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

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

    private async Task WithDbAsync(Func<AppDbContext, Task> action)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await action(db);
        await db.SaveChangesAsync();
    }

    private static Task<HttpResponseMessage> SetRoleAsync(HttpClient who, Guid group, Guid target, string role) =>
        who.PutAsJsonAsync($"/groups/{group}/members/{target}/role", new { role });

    private static Task<HttpResponseMessage> RecordTopicAsync(HttpClient who, Guid group) =>
        who.PutAsJsonAsync($"/groups/{group}/topic", new { });

    private static async Task ShouldBeErrorAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        response.StatusCode.Should().Be(status);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("code").GetString().Should().Be(code);
        body.GetProperty("error").GetString().Should().Be(code);
    }

    private static async Task<string> RoleOfAsync(HttpClient who, Guid group, Guid device)
    {
        var members = await who.GetFromJsonAsync<JsonElement>($"/groups/{group}/members");
        return members.EnumerateArray().Single(m => m.GetProperty("deviceId").GetGuid() == device)
            .GetProperty("role").GetString()!;
    }

    /// <summary>A completed hub round trip proves OnConnectedAsync registered the device.</summary>
    private async Task<(HubConnection Hub, TaskCompletionSource<JsonElement> Hint)> ListenAsync(string token)
    {
        var hub = new HubConnectionBuilder()
            .WithUrl($"{Factory.Server.BaseAddress}hub?access_token={token}",
                o => o.HttpMessageHandlerFactory = _ => Factory.Server.CreateHandler())
            .Build();
        var hint = new TaskCompletionSource<JsonElement>();
        hub.On<JsonElement>("GroupChanged", e => hint.TrySetResult(e));
        await hub.StartAsync();
        await hub.InvokeAsync("RequestPendingMessages");
        return (hub, hint);
    }

    // -----------------------------------------------------------------------
    // S1: member roles
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Admin_promotes_a_member_who_can_then_demote_the_creator()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http, member.Id);

        var promote = await SetRoleAsync(admin.Http, group, member.Id, "admin");

        promote.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await promote.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("deviceId").GetGuid().Should().Be(member.Id);
        body.GetProperty("role").GetString().Should().Be("admin");
        (await RoleOfAsync(admin.Http, group, member.Id)).Should().Be("admin");

        // The creator is only the first admin (decision 1).
        (await SetRoleAsync(member.Http, group, admin.Id, "member")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await RoleOfAsync(member.Http, group, admin.Id)).Should().Be("member");
        // ...and lost the admin rights with it.
        (await SetRoleAsync(admin.Http, group, member.Id, "member")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Same_role_is_idempotent()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http, member.Id);

        (await SetRoleAsync(admin.Http, group, member.Id, "member")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await SetRoleAsync(admin.Http, group, member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);
        var again = await SetRoleAsync(admin.Http, group, member.Id, "admin");

        again.StatusCode.Should().Be(HttpStatusCode.OK);
        (await again.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("role").GetString().Should().Be("admin");
        // The only admin "demoting" an already-member target is a no-op, not last_admin.
        (await SetRoleAsync(admin.Http, group, admin.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Last_admin_cannot_be_demoted_also_not_by_itself()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http, member.Id);

        await ShouldBeErrorAsync(await SetRoleAsync(admin.Http, group, admin.Id, "member"),
            HttpStatusCode.Conflict, "last_admin");
        (await RoleOfAsync(admin.Http, group, admin.Id)).Should().Be("admin");

        // With a second admin the demotion is allowed.
        (await SetRoleAsync(admin.Http, group, member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await SetRoleAsync(admin.Http, group, admin.Id, "member")).StatusCode.Should().Be(HttpStatusCode.OK);
        await ShouldBeErrorAsync(await SetRoleAsync(member.Http, group, member.Id, "member"),
            HttpStatusCode.Conflict, "last_admin");
    }

    [Fact]
    public async Task Two_admins_demoting_each_other_at_once_leave_one_admin()
    {
        var a = await DeviceAsync();
        var b = await DeviceAsync();
        var group = await CreateGroupAsync(a.Http, b.Id);
        (await SetRoleAsync(a.Http, group, b.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);

        var results = await Task.WhenAll(
            SetRoleAsync(a.Http, group, b.Id, "member"),
            SetRoleAsync(b.Http, group, a.Id, "member"));

        // Exactly one wins; the other is either last_admin or 403 (no longer an admin).
        results.Count(r => r.StatusCode == HttpStatusCode.OK).Should().Be(1);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.GroupMembers.CountAsync(m => m.GroupId == group && m.Role == "admin")).Should().Be(1);
    }

    [Fact]
    public async Task Bot_cannot_be_promoted_and_the_auditor_role_is_immutable()
    {
        var admin = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var auditor = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http, bot.Id, auditor.Id);
        await WithDbAsync(async db =>
            (await db.GroupMembers.SingleAsync(m => m.GroupId == group && m.DeviceId == auditor.Id)).Role = "auditor");

        await ShouldBeErrorAsync(await SetRoleAsync(admin.Http, group, bot.Id, "admin"),
            HttpStatusCode.BadRequest, "bot_cannot_be_admin");
        // Keeping a bot a member is harmless and stays idempotent.
        (await SetRoleAsync(admin.Http, group, bot.Id, "member")).StatusCode.Should().Be(HttpStatusCode.OK);
        await ShouldBeErrorAsync(await SetRoleAsync(admin.Http, group, auditor.Id, "admin"),
            HttpStatusCode.Conflict, "auditor_immutable");
        await ShouldBeErrorAsync(await SetRoleAsync(admin.Http, group, auditor.Id, "member"),
            HttpStatusCode.Conflict, "auditor_immutable");
        (await RoleOfAsync(admin.Http, group, bot.Id)).Should().Be("member");
        (await RoleOfAsync(admin.Http, group, auditor.Id)).Should().Be("auditor");
    }

    [Fact]
    public async Task Role_change_uses_the_add_member_gate()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var outsider = await DeviceAsync();
        var adminWeb = await DeviceAsync();
        await LinkAsync(admin.Id, adminWeb.Id);
        var group = await CreateGroupAsync(admin.Http, member.Id);

        foreach (var who in new[] { member.Http, outsider.Http, adminWeb.Http })
            (await SetRoleAsync(who, group, member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SetRoleAsync(admin.Http, Guid.NewGuid(), member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await SetRoleAsync(Client, group, member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await RoleOfAsync(admin.Http, group, member.Id)).Should().Be("member");
    }

    [Fact]
    public async Task Unknown_member_is_404_and_bad_role_is_400()
    {
        var admin = await DeviceAsync();
        var outsider = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);

        await ShouldBeErrorAsync(await SetRoleAsync(admin.Http, group, outsider.Id, "admin"),
            HttpStatusCode.NotFound, "not_a_member");
        foreach (var role in new[] { "auditor", "owner", "", "ADMIN" })
            await ShouldBeErrorAsync(await SetRoleAsync(admin.Http, group, admin.Id, role),
                HttpStatusCode.BadRequest, "invalid_role");
        var missing = await admin.Http.PutAsJsonAsync($"/groups/{group}/members/{admin.Id}/role", new { });
        await ShouldBeErrorAsync(missing, HttpStatusCode.BadRequest, "invalid_role");
    }

    [Fact]
    public async Task Role_change_sends_GroupChanged()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, member.Id, bot.Id);
        var (hub, hint) = await ListenAsync(bot.Token);
        await using var _ = hub;

        (await SetRoleAsync(admin.Http, group, member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);

        (await hint.Task.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("groupId").GetGuid().Should().Be(group);
    }

    // -----------------------------------------------------------------------
    // S2 / S3: topic record
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Never_set_topic_reads_as_null()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);

        var info = await admin.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}");

        info.GetProperty("topic").ValueKind.Should().Be(JsonValueKind.Null);
    }

    [Fact]
    public async Task Admin_records_strictly_increasing_versions_and_members_read_the_record()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var memberWeb = await DeviceAsync();
        await LinkAsync(member.Id, memberWeb.Id);
        var group = await CreateGroupAsync(admin.Http, member.Id);
        var before = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        var first = await RecordTopicAsync(admin.Http, group);
        first.StatusCode.Should().Be(HttpStatusCode.OK);
        var r1 = await first.Content.ReadFromJsonAsync<JsonElement>();
        var v1 = r1.GetProperty("version").GetInt64();
        v1.Should().BeGreaterThanOrEqualTo(before);
        r1.GetProperty("updatedBy").GetGuid().Should().Be(admin.Id);
        // Lower-case on the wire: receivers compare it with the sender identity as a string.
        r1.GetProperty("updatedBy").GetString().Should().Be(admin.Id.ToString());
        r1.GetProperty("updatedAt").GetDateTimeOffset().Should().BeCloseTo(DateTimeOffset.UtcNow, TimeSpan.FromMinutes(1));

        var versions = new List<long> { v1 };
        for (var i = 0; i < 3; i++)
            versions.Add((await (await RecordTopicAsync(admin.Http, group)).Content.ReadFromJsonAsync<JsonElement>())
                .GetProperty("version").GetInt64());
        versions.Should().BeInAscendingOrder().And.OnlyHaveUniqueItems();

        // Every member and their companions read the CURRENT record.
        foreach (var who in new[] { member.Http, memberWeb.Http })
        {
            var topic = (await who.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("topic");
            topic.GetProperty("version").GetInt64().Should().Be(versions[^1]);
            topic.GetProperty("updatedBy").GetGuid().Should().Be(admin.Id);
        }
    }

    [Fact]
    public async Task Version_keeps_increasing_past_a_future_stored_value()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);
        var future = DateTimeOffset.UtcNow.AddDays(1).ToUnixTimeMilliseconds();
        await WithDbAsync(async db => (await db.Groups.SingleAsync(g => g.GroupId == group)).TopicVersion = future);

        var record = await (await RecordTopicAsync(admin.Http, group)).Content.ReadFromJsonAsync<JsonElement>();

        record.GetProperty("version").GetInt64().Should().Be(future + 1);
    }

    [Fact]
    public async Task Concurrent_admins_get_distinct_versions_naming_themselves()
    {
        var a = await DeviceAsync();
        var b = await DeviceAsync();
        var group = await CreateGroupAsync(a.Http, b.Id);
        (await SetRoleAsync(a.Http, group, b.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);

        var calls = Enumerable.Range(0, 6).Select(i => (Who: i % 2 == 0 ? a : b, Task: RecordTopicAsync(i % 2 == 0 ? a.Http : b.Http, group))).ToList();
        await Task.WhenAll(calls.Select(c => c.Task));

        var records = new List<(long Version, Guid By, Guid Caller)>();
        foreach (var c in calls)
        {
            var body = await (await c.Task).Content.ReadFromJsonAsync<JsonElement>();
            records.Add((body.GetProperty("version").GetInt64(), body.GetProperty("updatedBy").GetGuid(), c.Who.Id));
        }
        records.Select(r => r.Version).Should().OnlyHaveUniqueItems();
        records.Should().OnlyContain(r => r.By == r.Caller);
        var current = (await a.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("topic");
        current.GetProperty("version").GetInt64().Should().Be(records.Max(r => r.Version));
        current.GetProperty("updatedBy").GetGuid().Should().Be(records.MaxBy(r => r.Version).By);
    }

    [Fact]
    public async Task Only_admins_record_a_topic()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var outsider = await DeviceAsync();
        var adminWeb = await DeviceAsync();
        await LinkAsync(admin.Id, adminWeb.Id);
        var group = await CreateGroupAsync(admin.Http, member.Id);

        foreach (var who in new[] { member.Http, outsider.Http, adminWeb.Http })
            (await RecordTopicAsync(who, group)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await RecordTopicAsync(admin.Http, Guid.NewGuid())).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await RecordTopicAsync(Client, group)).StatusCode.Should().Be(HttpStatusCode.Unauthorized);

        (await member.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}"))
            .GetProperty("topic").ValueKind.Should().Be(JsonValueKind.Null);

        // A promoted member may (decision 1), and the record names it.
        (await SetRoleAsync(admin.Http, group, member.Id, "admin")).StatusCode.Should().Be(HttpStatusCode.OK);
        var record = await (await RecordTopicAsync(member.Http, group)).Content.ReadFromJsonAsync<JsonElement>();
        record.GetProperty("updatedBy").GetGuid().Should().Be(member.Id);
    }

    [Fact]
    public async Task Topic_body_is_ignored_so_content_never_reaches_the_server()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);

        var response = await admin.Http.PutAsJsonAsync($"/groups/{group}/topic", new { topic = "secret", version = 1 });

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("version").GetInt64().Should().BeGreaterThan(1);
    }

    [Fact]
    public async Task Business_group_refuses_topics()
    {
        var admin = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http);
        await WithDbAsync(async db =>
            (await db.Groups.SingleAsync(g => g.GroupId == group)).OrganizationId = Guid.NewGuid());

        await ShouldBeErrorAsync(await RecordTopicAsync(admin.Http, group), HttpStatusCode.Conflict, "business_group");
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Groups.AsNoTracking().SingleAsync(g => g.GroupId == group)).TopicVersion.Should().BeNull();
    }

    [Fact]
    public async Task Topic_record_sends_GroupChanged()
    {
        var admin = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, bot.Id);
        var (hub, hint) = await ListenAsync(bot.Token);
        await using var _ = hub;

        (await RecordTopicAsync(admin.Http, group)).StatusCode.Should().Be(HttpStatusCode.OK);

        (await hint.Task.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("groupId").GetGuid().Should().Be(group);
    }

    // -----------------------------------------------------------------------
    // S4: bot-talk flags (T3 botsReadAll, T4 replyWithoutMention)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Bot_reading_flags_default_off_are_stored_returned_and_kept_when_omitted()
    {
        var admin = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var group = await CreateGroupAsync(admin.Http, bot.Id);

        var initial = (await bot.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("botTalk");
        initial.GetProperty("botsReadAll").GetBoolean().Should().BeFalse();
        initial.GetProperty("replyWithoutMention").GetBoolean().Should().BeFalse();

        var set = await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk",
            new { mode = "off", botsReadAll = true, replyWithoutMention = true });
        set.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await set.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("botsReadAll").GetBoolean().Should().BeTrue();
        body.GetProperty("replyWithoutMention").GetBoolean().Should().BeTrue();

        // An old app flipping only the mode keeps both flags (S4), the bot reads them.
        var old = await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk",
            new { mode = "all", allowedBotDeviceIds = Array.Empty<Guid>(), maxBotTurns = 5, pauseMinutes = 30 });
        (await old.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("botsReadAll").GetBoolean().Should().BeTrue();
        var seen = (await bot.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("botTalk");
        seen.GetProperty("mode").GetString().Should().Be("all");
        seen.GetProperty("botsReadAll").GetBoolean().Should().BeTrue();
        seen.GetProperty("replyWithoutMention").GetBoolean().Should().BeTrue();

        // Explicit false and null: false switches off, null keeps.
        var off = await admin.Http.PutAsJsonAsync($"/groups/{group}/bot-talk",
            new { mode = "all", botsReadAll = false, replyWithoutMention = (bool?)null });
        var offBody = await off.Content.ReadFromJsonAsync<JsonElement>();
        offBody.GetProperty("botsReadAll").GetBoolean().Should().BeFalse();
        offBody.GetProperty("replyWithoutMention").GetBoolean().Should().BeTrue();
    }

    [Fact]
    public async Task Bot_reading_flags_are_admin_only()
    {
        var admin = await DeviceAsync();
        var member = await DeviceAsync();
        var group = await CreateGroupAsync(admin.Http, member.Id);

        (await member.Http.PutAsJsonAsync($"/groups/{group}/bot-talk",
            new { mode = "off", botsReadAll = true, replyWithoutMention = true }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var botTalk = (await member.Http.GetFromJsonAsync<JsonElement>($"/groups/{group}")).GetProperty("botTalk");
        botTalk.GetProperty("botsReadAll").GetBoolean().Should().BeFalse();
        botTalk.GetProperty("replyWithoutMention").GetBoolean().Should().BeFalse();
    }
}
