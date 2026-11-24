// ---------------------------------------------------------------------------
// UserSafetyTests.cs - block and report a user (spec 2026-11-14-go-live)
// ---------------------------------------------------------------------------
// Real Postgres through the shared Testcontainers fixture (IntegrationTestBase).
// Hub sends are checked through the QueuedMessages table: a dropped copy is
// never stored, and the sender's call must still complete without error
// (D2: being blocked is not observable).
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
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class UserSafetyTests : IntegrationTestBase
{
    private static readonly string Body = Convert.ToBase64String([1, 2, 3]);

    private sealed record TestDevice(Guid DeviceId, string Token, HttpClient Http, string Handle);

    private async Task<TestDevice> NewDeviceAsync()
    {
        var http = Factory.CreateClient();
        var reg = await http.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06])
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = body.GetProperty("deviceId").GetGuid();
        var token = (await (await http.PostAsJsonAsync("/auth/token",
                new { deviceId, deviceSecret = body.GetProperty("deviceSecret").GetString() }))
            .Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return new TestDevice(deviceId, token, http, body.GetProperty("userHandle").GetString()!);
    }

    private HubConnection Hub(TestDevice device) => new HubConnectionBuilder()
        .WithUrl($"{Factory.Server.BaseAddress}hub?access_token={device.Token}",
            o => o.HttpMessageHandlerFactory = _ => Factory.Server.CreateHandler())
        .Build();

    private async Task LinkAsync(Guid primary, params Guid[] companions)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.DeviceLists.Add(new DeviceList
        {
            PrimaryDeviceId = primary, Version = 1, Payload = [1], Signature = new byte[64],
            UpdatedAt = DateTimeOffset.UtcNow,
            Members = companions.Select(c => new DeviceListMember { DeviceId = c, PrimaryDeviceId = primary }).ToList()
        });
        await db.SaveChangesAsync();
    }

    private async Task<Guid> GroupAsync(params Guid[] members)
    {
        var groupId = Guid.NewGuid();
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.Groups.Add(new Group { GroupId = groupId, CreatedBy = members[0], CreatedAt = DateTimeOffset.UtcNow });
        foreach (var m in members)
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = m, Role = m == members[0] ? "admin" : "member", JoinedAt = DateTimeOffset.UtcNow });
        await db.SaveChangesAsync();
        return groupId;
    }

    private async Task<List<Guid>> QueuedForAsync(Guid messageId)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.QueuedMessages.Where(m => m.MessageId == messageId).Select(m => m.RecipientId).ToListAsync();
    }

    private static Dictionary<Guid, string> Payloads(params Guid[] ids) => ids.ToDictionary(id => id, _ => Body);

    private static async Task BlockAsync(TestDevice blocker, Guid target) =>
        (await blocker.Http.PutAsync($"/blocks/{target}", null)).StatusCode.Should().Be(HttpStatusCode.NoContent);

    private static async Task<string?> CodeAsync(HttpResponseMessage response) =>
        (await response.Content.ReadFromJsonAsync<JsonElement>()).TryGetProperty("code", out var c) ? c.GetString() : null;

    // -----------------------------------------------------------------------
    // S2-S4: block list endpoints
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Block_list_is_per_identity_and_idempotent()
    {
        var me = await NewDeviceAsync();
        var myWeb = await NewDeviceAsync();
        var them = await NewDeviceAsync();
        var theirWeb = await NewDeviceAsync();
        await LinkAsync(me.DeviceId, myWeb.DeviceId);
        await LinkAsync(them.DeviceId, theirWeb.DeviceId);

        // Blocking their COMPANION from MY companion blocks identity -> identity.
        await BlockAsync(myWeb, theirWeb.DeviceId);
        await BlockAsync(me, them.DeviceId);

        var list = await me.Http.GetFromJsonAsync<JsonElement>("/blocks");
        var entry = list.GetProperty("blocks").EnumerateArray().Single();
        entry.GetProperty("deviceId").GetGuid().Should().Be(them.DeviceId);
        entry.GetProperty("userHandle").GetString().Should().Be(them.Handle);
        entry.GetProperty("isBot").GetBoolean().Should().BeFalse();
        (await myWeb.Http.GetFromJsonAsync<JsonElement>("/blocks")).GetProperty("blocks").GetArrayLength().Should().Be(1);

        (await me.Http.DeleteAsync($"/blocks/{theirWeb.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await me.Http.DeleteAsync($"/blocks/{theirWeb.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await me.Http.GetFromJsonAsync<JsonElement>("/blocks")).GetProperty("blocks").GetArrayLength().Should().Be(0);
    }

    [Fact]
    public async Task Blocking_self_or_an_unknown_device_is_refused()
    {
        var me = await NewDeviceAsync();
        var myWeb = await NewDeviceAsync();
        await LinkAsync(me.DeviceId, myWeb.DeviceId);

        var self = await me.Http.PutAsync($"/blocks/{myWeb.DeviceId}", null);
        self.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await CodeAsync(self)).Should().Be("cannot_block_self");

        var unknown = await me.Http.PutAsync($"/blocks/{Guid.NewGuid()}", null);
        unknown.StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await CodeAsync(unknown)).Should().Be("unknown_device");

        using var anonymous = Factory.CreateClient();
        (await anonymous.GetAsync("/blocks")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    // -----------------------------------------------------------------------
    // D2 / S5: enforcement on the send paths
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Blocked_identity_reaches_no_device_of_the_blocker_on_any_1to1_path()
    {
        var victim = await NewDeviceAsync();
        var victimWeb = await NewDeviceAsync();
        var troll = await NewDeviceAsync();
        var bystander = await NewDeviceAsync();
        await LinkAsync(victim.DeviceId, victimWeb.DeviceId);
        await BlockAsync(victimWeb, troll.DeviceId);

        await using var hub = Hub(troll);
        await hub.StartAsync();

        var legacy = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessage", victim.DeviceId, legacy, Body);
        var legacyToCompanion = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessage", victimWeb.DeviceId, legacyToCompanion, Body);
        var silent = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessageSilent", victim.DeviceId, silent, Body);
        var fanout = Guid.NewGuid();
        var targets = new[] { victim.DeviceId, victimWeb.DeviceId };
        await hub.InvokeAsync("SendReliableDirectFanout", victim.DeviceId, fanout, targets, Payloads(targets));

        (await QueuedForAsync(legacy)).Should().BeEmpty();
        (await QueuedForAsync(legacyToCompanion)).Should().BeEmpty();
        (await QueuedForAsync(silent)).Should().BeEmpty();
        (await QueuedForAsync(fanout)).Should().BeEmpty();

        // Others are unaffected, and so is the opposite direction.
        var toBystander = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessage", bystander.DeviceId, toBystander, Body);
        (await QueuedForAsync(toBystander)).Should().Equal(bystander.DeviceId);
        await using var victimHub = Hub(victim);
        await victimHub.StartAsync();
        var fromVictim = Guid.NewGuid();
        await victimHub.InvokeAsync("SendReliableDirectFanout", troll.DeviceId, fromVictim,
            new[] { troll.DeviceId, victimWeb.DeviceId }, Payloads(troll.DeviceId, victimWeb.DeviceId));
        (await QueuedForAsync(fromVictim)).Should().BeEquivalentTo(new[] { troll.DeviceId, victimWeb.DeviceId });

        // Unblock: the next message goes through.
        (await victim.Http.DeleteAsync($"/blocks/{troll.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        var after = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessage", victim.DeviceId, after, Body);
        (await QueuedForAsync(after)).Should().Equal(victim.DeviceId);
    }

    [Fact]
    public async Task Blocked_identity_reaches_only_the_other_members_of_a_shared_group()
    {
        var victim = await NewDeviceAsync();
        var troll = await NewDeviceAsync();
        var other = await NewDeviceAsync();
        var group = await GroupAsync(troll.DeviceId, victim.DeviceId, other.DeviceId);
        await BlockAsync(victim, troll.DeviceId);

        await using var hub = Hub(troll);
        await hub.StartAsync();
        var targets = new[] { victim.DeviceId, other.DeviceId };

        var fanout = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableGroupFanout", group, fanout, targets, Payloads(targets));
        (await QueuedForAsync(fanout)).Should().Equal(other.DeviceId);

        var legacy = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableGroupMessage", group, legacy, Payloads(targets));
        (await QueuedForAsync(legacy)).Should().Equal(other.DeviceId);

        var silent = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableGroupFanoutSilent", group, silent, targets, Payloads(targets));
        (await QueuedForAsync(silent)).Should().Equal(other.DeviceId);
    }

    [Fact]
    public async Task Blocked_caller_signals_and_typing_never_reach_the_blocker()
    {
        var victim = await NewDeviceAsync();
        var troll = await NewDeviceAsync();
        var friend = await NewDeviceAsync();
        await BlockAsync(victim, troll.DeviceId);

        var signals = new List<string>();
        var typing = new List<string>();
        await using var victimHub = Hub(victim);
        victimHub.On<JsonElement>("CallSignal", e => { lock (signals) signals.Add(e.GetProperty("senderId").GetString()!); });
        victimHub.On<JsonElement>("TypingIndicator", e => { lock (typing) typing.Add(e.GetProperty("senderId").GetString()!); });
        await victimHub.StartAsync();

        await using var trollHub = Hub(troll);
        await trollHub.StartAsync();
        // No exception: the caller cannot tell a block from an unanswered call.
        await trollHub.InvokeAsync("CallSignal", victim.DeviceId, "offer", "{\"callId\":\"c1\"}");
        await trollHub.InvokeAsync("CallSignal", victim.DeviceId, "ice", "{\"callId\":\"c1\"}");
        await trollHub.InvokeAsync("TypingIndicator", victim.DeviceId.ToString());

        // A control sender that is NOT blocked proves the events would arrive.
        await using var friendHub = Hub(friend);
        await friendHub.StartAsync();
        await friendHub.InvokeAsync("CallSignal", victim.DeviceId, "offer", "{\"callId\":\"c2\"}");
        await friendHub.InvokeAsync("TypingIndicator", victim.DeviceId.ToString());

        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            lock (signals) lock (typing)
                if (signals.Count > 0 && typing.Count > 0) break;
            await Task.Delay(50);
        }
        lock (signals) signals.Should().Equal(friend.DeviceId.ToString());
        lock (typing) typing.Should().Equal(friend.DeviceId.ToString());

        // Offline blocker: the offer is dropped without an error as well.
        await victimHub.StopAsync();
        await trollHub.InvokeAsync("CallSignal", victim.DeviceId, "offer", "{\"callId\":\"c3\"}");
    }

    [Fact]
    public async Task Blocking_deletes_what_the_blocked_identity_already_queued()
    {
        var victim = await NewDeviceAsync();
        var troll = await NewDeviceAsync();
        var trollWeb = await NewDeviceAsync();
        await LinkAsync(troll.DeviceId, trollWeb.DeviceId);
        var other = await NewDeviceAsync();

        await using var hub = Hub(trollWeb);
        await hub.StartAsync();
        var waiting = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessage", victim.DeviceId, waiting, Body);
        var toOther = Guid.NewGuid();
        await hub.InvokeAsync("SendReliableMessage", other.DeviceId, toOther, Body);
        (await QueuedForAsync(waiting)).Should().Equal(victim.DeviceId);

        await BlockAsync(victim, troll.DeviceId);

        (await QueuedForAsync(waiting)).Should().BeEmpty("D3: a block also stops what is already waiting");
        (await QueuedForAsync(toOther)).Should().Equal(other.DeviceId);
    }

    // -----------------------------------------------------------------------
    // S7: POST /users/{deviceId}/report
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Report_stores_the_evidence_and_returns_a_receipt()
    {
        var reporter = await NewDeviceAsync();
        var troll = await NewDeviceAsync();
        var trollWeb = await NewDeviceAsync();
        await LinkAsync(troll.DeviceId, trollWeb.DeviceId);
        var groupId = Guid.NewGuid();

        // Reporting the companion reports the identity (its primary).
        var response = await reporter.Http.PostAsJsonAsync($"/users/{trollWeb.DeviceId}/report", new
        {
            category = "illegal",
            reason = "threats",
            goodFaith = true,
            groupId,
            messages = new[]
            {
                new { messageId = "a", sentAt = (DateTimeOffset?)DateTimeOffset.UtcNow, text = "I will find you" },
                new { messageId = (string?)null!, sentAt = (DateTimeOffset?)null, text = "second" }
            }
        });
        response.StatusCode.Should().Be(HttpStatusCode.OK, await response.Content.ReadAsStringAsync());
        var receipt = await response.Content.ReadFromJsonAsync<JsonElement>();
        var reportId = receipt.GetProperty("reportId").GetInt64();

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var stored = await db.UserReports.SingleAsync(r => r.Id == reportId);
        stored.ReporterDeviceId.Should().Be(reporter.DeviceId);
        stored.ReportedPrimaryId.Should().Be(troll.DeviceId);
        stored.ReportedHandle.Should().Be(troll.Handle);
        stored.GroupId.Should().Be(groupId);
        stored.Category.Should().Be("illegal");
        stored.Status.Should().Be("open");
        stored.CreatedAt.Should().Be(receipt.GetProperty("createdAt").GetDateTimeOffset());
        var evidence = JsonDocument.Parse(stored.EvidenceJson).RootElement;
        evidence.GetArrayLength().Should().Be(2);
        evidence[0].GetProperty("text").GetString().Should().Be("I will find you");
    }

    [Theory]
    [InlineData("bogus", "x", null, false, 0, 1, "invalid_category")]
    [InlineData("terms", "", null, false, 0, 1, "invalid_reason")]
    [InlineData("terms", "x", "no-at-sign", false, 0, 1, "invalid_contact")]
    [InlineData("illegal", "x", null, false, 0, 1, "good_faith_required")]
    [InlineData("spam", "x", null, false, 21, 1, "invalid_evidence")]
    [InlineData("spam", "x", null, false, 1, 4001, "invalid_evidence")]
    [InlineData("spam", "x", null, false, 1, 0, "invalid_evidence")]
    public async Task Report_validation(string category, string reason, string? email, bool goodFaith,
        int messages, int textLength, string code)
    {
        var reporter = await NewDeviceAsync();
        var troll = await NewDeviceAsync();
        var response = await reporter.Http.PostAsJsonAsync($"/users/{troll.DeviceId}/report", new
        {
            category,
            reason,
            contactEmail = email,
            goodFaith,
            messages = Enumerable.Range(0, messages).Select(_ => new { text = new string('a', textLength) }).ToList()
        });
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await CodeAsync(response)).Should().Be(code);
    }

    [Fact]
    public async Task Report_refuses_self_and_unknown_devices()
    {
        var me = await NewDeviceAsync();
        var myWeb = await NewDeviceAsync();
        await LinkAsync(me.DeviceId, myWeb.DeviceId);

        var self = await me.Http.PostAsJsonAsync($"/users/{myWeb.DeviceId}/report", new { reason = "x" });
        self.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await CodeAsync(self)).Should().Be("cannot_report_self");

        var unknown = await me.Http.PostAsJsonAsync($"/users/{Guid.NewGuid()}/report", new { reason = "x" });
        unknown.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Report_budget_is_per_identity_and_per_day()
    {
        // Default budget (Moderation:MaxUserReportsPerDay = 10), so the test
        // also pins the documented default.
        var me = await NewDeviceAsync();
        var myWeb = await NewDeviceAsync();
        await LinkAsync(me.DeviceId, myWeb.DeviceId);
        var troll = await NewDeviceAsync();

        for (var i = 0; i < 10; i++)
        {
            // Alternating devices: a companion must not double the budget.
            var device = i % 2 == 0 ? me : myWeb;
            (await device.Http.PostAsJsonAsync($"/users/{troll.DeviceId}/report", new { reason = $"r{i}" }))
                .StatusCode.Should().Be(HttpStatusCode.OK);
        }
        var over = await myWeb.Http.PostAsJsonAsync($"/users/{troll.DeviceId}/report", new { reason = "over" });
        over.StatusCode.Should().Be((HttpStatusCode)429);
        (await CodeAsync(over)).Should().Be("report_limit_reached");
    }

    // -----------------------------------------------------------------------
    // D9 / S12: retention
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Cleanup_deletes_user_reports_past_retention_only()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var now = DateTimeOffset.UtcNow;
        db.UserReports.AddRange(
            new UserReport { ReporterDeviceId = Guid.NewGuid(), ReportedPrimaryId = Guid.NewGuid(), Reason = "old", CreatedAt = now.AddDays(-181) },
            new UserReport { ReporterDeviceId = Guid.NewGuid(), ReportedPrimaryId = Guid.NewGuid(), Reason = "new", CreatedAt = now.AddDays(-179) });
        await db.SaveChangesAsync();

        (await MessageCleanupService.DeleteExpiredUserReportsAsync(db, 180, now, CancellationToken.None)).Should().Be(1);
        (await db.UserReports.Select(r => r.Reason).ToListAsync()).Should().Equal("new");
    }
}
