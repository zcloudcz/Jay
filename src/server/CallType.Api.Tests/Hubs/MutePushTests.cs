// ---------------------------------------------------------------------------
// MutePushTests.cs - mutes skip the push, never the message (design D6)
// ---------------------------------------------------------------------------
// Uses the same RecordingPush seam as FanoutHubTests: SendPushAsync is
// virtual, so a replaced singleton records who the hub tries to wake. All
// recipients stay offline, so every unmuted copy would be pushed.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Hubs;

public class MutePushTests : IntegrationTestBase
{
    private static readonly string Body = Convert.ToBase64String([1, 2, 3]);

    private sealed class RecordingPush(IServiceScopeFactory sf,
        IEnumerable<IPushSender> senders, ILogger<PushNotificationService> l) : PushNotificationService(sf, senders, l)
    {
        public readonly System.Collections.Concurrent.ConcurrentBag<Guid> Pushed = new();
        public override Task SendPushAsync(Guid recipientDeviceId, PushNotification notification) { Pushed.Add(recipientDeviceId); return Task.CompletedTask; }
    }

    private RecordingPush NewPush() => new(
        Factory.Services.GetRequiredService<IServiceScopeFactory>(),
        Factory.Services.GetServices<IPushSender>(),
        Factory.Services.GetRequiredService<ILogger<PushNotificationService>>());

    private static HubConnection Hub(WebApplicationFactory<Program> factory, string token) => new HubConnectionBuilder()
        .WithUrl($"{factory.Server.BaseAddress}hub?access_token={token}",
            o => o.HttpMessageHandlerFactory = _ => factory.Server.CreateHandler())
        .Build();

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
        var http = Factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (id, http, token);
    }

    private static async Task MuteGroupAsync(HttpClient http, Guid group, string mode, DateTimeOffset? until = null) =>
        (await http.PutAsJsonAsync($"/groups/{group}/mute", new { mode, until }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

    private async Task<int> QueuedCountAsync(Guid messageId)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.QueuedMessages.CountAsync(m => m.MessageId == messageId);
    }

    /// <summary>
    /// One group, one recipient per mute state. Returns who got pushed when
    /// <paramref name="senderIsBot"/> decides whether the sender is a bot.
    /// </summary>
    private async Task<(List<Guid> Pushed, Guid Off, Guid All, Guid Bots, Guid Expired, Guid OtherGroup, int Queued)>
        GroupSendAsync(bool senderIsBot)
    {
        var admin = await DeviceAsync();
        var sender = await DeviceAsync(senderIsBot);
        var off = await DeviceAsync();
        var all = await DeviceAsync();
        var bots = await DeviceAsync();
        var expired = await DeviceAsync();
        var otherGroup = await DeviceAsync();
        var members = new[] { sender.Id, off.Id, all.Id, bots.Id, expired.Id, otherGroup.Id };
        var created = await admin.Http.PostAsJsonAsync("/groups", new { memberDeviceIds = members });
        var group = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();
        var created2 = await admin.Http.PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { otherGroup.Id } });
        var group2 = (await created2.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        await MuteGroupAsync(all.Http, group, "all");
        await MuteGroupAsync(bots.Http, group, "bots", DateTimeOffset.UtcNow.AddHours(1));
        await MuteGroupAsync(expired.Http, group, "all", DateTimeOffset.UtcNow.AddMinutes(-5));
        // A mute of ANOTHER group must not leak into this one.
        await MuteGroupAsync(otherGroup.Http, group2, "all");

        var push = NewPush();
        await using var factory = Factory.WithWebHostBuilder(b =>
            b.ConfigureServices(sv => sv.AddSingleton<PushNotificationService>(push)));
        await using var hub = Hub(factory, sender.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var recipients = members.Where(id => id != sender.Id).ToDictionary(id => id, _ => Body);
        recipients[admin.Id] = Body;
        await hub.InvokeAsync("SendReliableGroupMessage", group, messageId, recipients);

        return (push.Pushed.ToList(), off.Id, all.Id, bots.Id, expired.Id, otherGroup.Id, await QueuedCountAsync(messageId));
    }

    [Fact]
    public async Task Group_message_from_a_human_skips_only_all_mutes()
    {
        var r = await GroupSendAsync(senderIsBot: false);

        r.Pushed.Should().Contain([r.Off, r.Bots, r.Expired, r.OtherGroup]);
        r.Pushed.Should().NotContain(r.All);
        // Muting skips the push only: every copy is still queued (6 recipients incl. admin).
        r.Queued.Should().Be(6);
    }

    [Fact]
    public async Task Group_message_from_a_bot_also_skips_bots_mutes()
    {
        var r = await GroupSendAsync(senderIsBot: true);

        r.Pushed.Should().Contain([r.Off, r.Expired, r.OtherGroup]);
        r.Pushed.Should().NotContain([r.All, r.Bots]);
        r.Queued.Should().Be(6);
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

    [Fact]
    public async Task Direct_mute_of_a_person_silences_all_of_their_devices()
    {
        var me = await DeviceAsync();
        var alicePhone = await DeviceAsync();
        var aliceWeb = await DeviceAsync();
        var bob = await DeviceAsync();
        await LinkAsync(alicePhone.Id, aliceWeb.Id);
        // Muted by naming Alice's companion; the server stores her identity.
        (await me.Http.PutAsJsonAsync($"/mutes/direct/{aliceWeb.Id}", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var push = NewPush();
        await using var factory = Factory.WithWebHostBuilder(b =>
            b.ConfigureServices(sv => sv.AddSingleton<PushNotificationService>(push)));

        // From Alice's PRIMARY over the legacy single-recipient path.
        await using (var hub = Hub(factory, alicePhone.Token))
        {
            await hub.StartAsync();
            await hub.InvokeAsync("SendReliableMessage", me.Id, Guid.NewGuid(), Body);
        }
        // From Alice's COMPANION over multi-device fan-out.
        var fanoutId = Guid.NewGuid();
        await using (var hub = Hub(factory, aliceWeb.Token))
        {
            await hub.StartAsync();
            var targets = new[] { me.Id, alicePhone.Id };
            await hub.InvokeAsync("SendReliableDirectFanout", me.Id, fanoutId, targets,
                targets.ToDictionary(id => id, _ => Body));
        }
        // Bob is not muted.
        await using (var hub = Hub(factory, bob.Token))
        {
            await hub.StartAsync();
            await hub.InvokeAsync("SendReliableMessage", me.Id, Guid.NewGuid(), Body);
        }

        push.Pushed.Should().Equal(me.Id);
        (await QueuedCountAsync(fanoutId)).Should().Be(2);
    }

    [Fact]
    public async Task Direct_bots_mute_silences_a_bot_but_an_expired_mute_silences_nothing()
    {
        var me = await DeviceAsync();
        var bot = await DeviceAsync(isBot: true);
        var human = await DeviceAsync();
        var other = await DeviceAsync();
        (await me.Http.PutAsJsonAsync($"/mutes/direct/{bot.Id}", new { mode = "bots" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await me.Http.PutAsJsonAsync($"/mutes/direct/{human.Id}", new { mode = "bots" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await other.Http.PutAsJsonAsync($"/mutes/direct/{bot.Id}",
                new { mode = "all", until = DateTimeOffset.UtcNow.AddSeconds(-1) }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var push = NewPush();
        await using var factory = Factory.WithWebHostBuilder(b =>
            b.ConfigureServices(sv => sv.AddSingleton<PushNotificationService>(push)));
        await using (var hub = Hub(factory, bot.Token))
        {
            await hub.StartAsync();
            await hub.InvokeAsync("SendReliableMessage", me.Id, Guid.NewGuid(), Body);
            await hub.InvokeAsync("SendReliableMessage", other.Id, Guid.NewGuid(), Body);
        }
        await using (var hub = Hub(factory, human.Token))
        {
            await hub.StartAsync();
            // "bots" mute of a human peer: the human still wakes me.
            await hub.InvokeAsync("SendReliableMessage", me.Id, Guid.NewGuid(), Body);
        }

        push.Pushed.Should().BeEquivalentTo(new[] { other.Id, me.Id });
    }
}
