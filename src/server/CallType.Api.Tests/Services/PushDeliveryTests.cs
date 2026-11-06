// ---------------------------------------------------------------------------
// PushDeliveryTests.cs - End-to-end push delivery with fake providers
// ---------------------------------------------------------------------------
// Real API + PostgreSQL, fake push services behind the named HttpClients:
// dead-token clearing per provider (410 / 404 / UNREGISTERED), locale-based
// texts, channel posts on every platform, and the hub's call and message
// pushes (offline offer -> incoming_call, mute "all" respected, routes).
// This is also the "fake push endpoint" integration test of spec section 3:
// the Web Push body that leaves the server is decrypted like a browser would.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class PushDeliveryTests : IntegrationTestBase
{
    private readonly FakePushService _service = new();

    /// <summary>All three providers configured, all talking to <see cref="_service"/>.</summary>
    private WebApplicationFactory<Program> PushFactory()
    {
        var (pem, key) = PushKeys.NewApnsKey();
        key.Dispose();
        var (pub, priv) = PushKeys.NewVapidKeys();
        return Factory.WithWebHostBuilder(b =>
        {
            b.ConfigureAppConfiguration((_, c) => c.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Push:Apns:KeyId"] = "ABC123DEFG",
                ["Push:Apns:PrivateKeyP8"] = pem,
                ["Push:WebPush:PublicKey"] = pub,
                ["Push:WebPush:PrivateKey"] = priv,
            }));
            b.ConfigureServices(sv =>
            {
                sv.AddSingleton<IFcmAccessTokenSource>(new FakeFcmTokens());
                foreach (var name in new[] { FcmSender.HttpClientName, ApnsSender.HttpClientName, WebPushSender.HttpClientName })
                    sv.AddHttpClient(name).ConfigurePrimaryHttpMessageHandler(() => _service.CreateHandler());
            });
        });
    }

    private async Task<(Guid Id, string Token, HttpClient Http)> DeviceAsync()
    {
        var reg = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([1, 2, 3]),
            signedPreKey = Convert.ToBase64String([4, 5, 6]),
        });
        var body = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var id = body.GetProperty("deviceId").GetGuid();
        var tokenResponse = await Client.PostAsJsonAsync("/auth/token",
            new { deviceId = id, deviceSecret = body.GetProperty("deviceSecret").GetString() });
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
        var http = Factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (id, token, http);
    }

    private static async Task RegisterPushAsync(HttpClient http, Guid id, string platform, string token,
        string? locale = null) =>
        (await http.PutAsJsonAsync($"/devices/{id}/push-token", new { platform, token, locale }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

    private async Task<string?> StoredTokenAsync(Guid id)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.Devices.Where(d => d.DeviceId == id).Select(d => d.PushToken).SingleAsync();
    }

    [Fact]
    public async Task Apns_410_clears_the_token_and_the_text_follows_the_locale()
    {
        var device = await DeviceAsync();
        await RegisterPushAsync(device.Http, device.Id, "apns", new string('c', 64), "cs");
        _service.Respond = _ => new HttpResponseMessage(HttpStatusCode.Gone)
            { Content = new StringContent("{\"reason\":\"Unregistered\"}") };
        await using var factory = PushFactory();
        var push = factory.Services.GetRequiredService<PushNotificationService>();

        await push.SendPushAsync(device.Id, new PushNotification(PushTypes.Message, "conv"));

        var request = _service.Requests.Single();
        request.Request.RequestUri!.AbsolutePath.Should().Be($"/3/device/{new string('c', 64)}");
        request.BodyText.Should().Contain("Nová zpráva");
        (await StoredTokenAsync(device.Id)).Should().BeNull();
    }

    [Fact]
    public async Task WebPush_404_clears_the_subscription_and_the_body_decrypts_like_a_browser()
    {
        var device = await DeviceAsync();
        var (json, key, auth) = PushKeys.NewSubscription();
        using var _k = key;
        await RegisterPushAsync(device.Http, device.Id, "webpush", json);
        _service.Respond = _ => new HttpResponseMessage(HttpStatusCode.NotFound);
        await using var factory = PushFactory();
        var push = factory.Services.GetRequiredService<PushNotificationService>();
        var group = Guid.NewGuid();

        await push.SendPushAsync(device.Id, PushNotification.ForMessage(group, Guid.NewGuid()));

        var request = _service.Requests.Single();
        var plain = JsonDocument.Parse(PushKeys.Decrypt(request.Body, key, auth)).RootElement;
        plain.GetProperty("type").GetString().Should().Be("group_message");
        plain.GetProperty("conversationId").GetString().Should().Be(group.ToString());
        plain.GetProperty("body").GetString().Should().Be("New message in a group");
        (await StoredTokenAsync(device.Id)).Should().BeNull();
    }

    [Fact]
    public async Task Fcm_unregistered_clears_the_token_but_a_transient_error_keeps_it()
    {
        var dead = await DeviceAsync();
        var flaky = await DeviceAsync();
        await RegisterPushAsync(dead.Http, dead.Id, "fcm", "dead-token");
        await RegisterPushAsync(flaky.Http, flaky.Id, "fcm", "flaky-token");
        _service.Respond = r => r.BodyText.Contains("dead-token")
            ? new HttpResponseMessage(HttpStatusCode.NotFound)
                { Content = new StringContent("{\"error\":{\"details\":[{\"errorCode\":\"UNREGISTERED\"}]}}") }
            : new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        await using var factory = PushFactory();
        var push = factory.Services.GetRequiredService<PushNotificationService>();

        await push.SendPushAsync(dead.Id, new PushNotification(PushTypes.Message, "c"));
        await push.SendPushAsync(flaky.Id, new PushNotification(PushTypes.Message, "c"));

        _service.Requests.Should().HaveCount(2);
        (await StoredTokenAsync(dead.Id)).Should().BeNull();
        (await StoredTokenAsync(flaky.Id)).Should().Be("flaky-token");
    }

    [Fact]
    public async Task Provider_exception_never_escapes_the_push_service()
    {
        var device = await DeviceAsync();
        await RegisterPushAsync(device.Http, device.Id, "apns", new string('d', 64));
        _service.Respond = _ => throw new HttpRequestException("network down");
        await using var factory = PushFactory();
        var push = factory.Services.GetRequiredService<PushNotificationService>();

        var act = () => push.SendPushAsync(device.Id, new PushNotification(PushTypes.Message, "c"));

        await act.Should().NotThrowAsync();
        (await StoredTokenAsync(device.Id)).Should().NotBeNull();
    }

    [Fact]
    public async Task Channel_post_pushes_offline_followers_on_every_platform()
    {
        var android = await DeviceAsync();
        var iphone = await DeviceAsync();
        var browser = await DeviceAsync();
        var online = await DeviceAsync();
        var (json, key, auth) = PushKeys.NewSubscription();
        using var _k = key;
        await RegisterPushAsync(android.Http, android.Id, "fcm", "android-token");
        await RegisterPushAsync(iphone.Http, iphone.Id, "apns", new string('e', 64));
        await RegisterPushAsync(browser.Http, browser.Id, "webpush", json);
        await RegisterPushAsync(online.Http, online.Id, "fcm", "online-token");
        var channelId = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var account = new Account { AccountId = Guid.NewGuid(), Email = $"{Guid.NewGuid()}@t.cz", CreatedAt = DateTimeOffset.UtcNow };
            db.Accounts.Add(account);
            db.Channels.Add(new Channel
            {
                ChannelId = channelId, Handle = "CH-PUSH-0001", Name = "n", OwnerDeviceId = android.Id,
                OwnerAccountId = account.AccountId, CreatedAt = DateTimeOffset.UtcNow,
            });
            foreach (var d in new[] { android.Id, iphone.Id, browser.Id, online.Id })
                db.ChannelFollowers.Add(new ChannelFollower { ChannelId = channelId, DeviceId = d, FollowedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync();
        }
        await using var factory = PushFactory();
        var push = factory.Services.GetRequiredService<PushNotificationService>();

        await push.SendChannelPostPushAsync(channelId, TimeSpan.FromMinutes(5), id => id == online.Id);

        var requests = _service.Requests.ToList();
        requests.Should().HaveCount(3);
        requests.Select(r => r.Request.RequestUri!.Host).Should().BeEquivalentTo(
            ["fcm.googleapis.com", "api.push.apple.com", "push.example.net"]);
        requests.Should().NotContain(r => r.BodyText.Contains("online-token"));
        requests.Single(r => r.Request.RequestUri!.Host == "api.push.apple.com").BodyText
            .Should().Contain($"\"thread-id\":\"{channelId}\"").And.Contain("\"type\":\"channel_post\"");
        var web = requests.Single(r => r.Request.RequestUri!.Host == "push.example.net");
        JsonDocument.Parse(PushKeys.Decrypt(web.Body, key, auth)).RootElement
            .GetProperty("conversationId").GetString().Should().Be(channelId.ToString());
    }

    // -----------------------------------------------------------------------
    // Hub: who gets which push
    // -----------------------------------------------------------------------

    private sealed class RecordingPush(IServiceScopeFactory sf, IEnumerable<IPushSender> senders,
        ILogger<PushNotificationService> l) : PushNotificationService(sf, senders, l)
    {
        public readonly ConcurrentQueue<(Guid Device, PushNotification Notification)> Pushed = new();

        public override Task SendPushAsync(Guid recipientDeviceId, PushNotification notification)
        {
            Pushed.Enqueue((recipientDeviceId, notification));
            return Task.CompletedTask;
        }
    }

    private (WebApplicationFactory<Program> Factory, RecordingPush Push) RecordingFactory()
    {
        var push = new RecordingPush(Factory.Services.GetRequiredService<IServiceScopeFactory>(),
            Factory.Services.GetServices<IPushSender>(),
            Factory.Services.GetRequiredService<ILogger<PushNotificationService>>());
        return (Factory.WithWebHostBuilder(b => b.ConfigureServices(sv => sv.AddSingleton<PushNotificationService>(push))),
            push);
    }

    private static HubConnection Hub(WebApplicationFactory<Program> factory, string token) => new HubConnectionBuilder()
        .WithUrl($"{factory.Server.BaseAddress}hub?access_token={token}",
            o => o.HttpMessageHandlerFactory = _ => factory.Server.CreateHandler())
        .Build();

    [Fact]
    public async Task Offline_offer_pushes_incoming_call_routed_to_the_caller()
    {
        var caller = await DeviceAsync();
        var callee = await DeviceAsync();
        var (factory, push) = RecordingFactory();
        await using var _f = factory;
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", "{}");
        // Later signals of the same (dead) call never push again.
        await hub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", "{}");
        await hub.InvokeAsync("CallSignal", callee.Id, "hangup", "{}");

        push.Pushed.Should().Equal((callee.Id, new PushNotification("incoming_call", caller.Id.ToString())));
    }

    [Fact]
    public async Task Call_push_respects_only_a_full_direct_mute()
    {
        var caller = await DeviceAsync();
        var mutedAll = await DeviceAsync();
        var mutedBots = await DeviceAsync();
        (await mutedAll.Http.PutAsJsonAsync($"/mutes/direct/{caller.Id}", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await mutedBots.Http.PutAsJsonAsync($"/mutes/direct/{caller.Id}", new { mode = "bots" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        var (factory, push) = RecordingFactory();
        await using var _f = factory;
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", mutedAll.Id, "offer", "{}");
        await hub.InvokeAsync("CallSignal", mutedBots.Id, "offer", "{}");

        push.Pushed.Select(p => p.Device).Should().Equal(mutedBots.Id);
    }

    [Fact]
    public async Task Online_callee_gets_the_signal_and_no_push()
    {
        var caller = await DeviceAsync();
        var callee = await DeviceAsync();
        var (factory, push) = RecordingFactory();
        await using var _f = factory;
        await using var calleeHub = Hub(factory, callee.Token);
        var got = new TaskCompletionSource<JsonElement>();
        calleeHub.On<JsonElement>("CallSignal", e => got.TrySetResult(e));
        await calleeHub.StartAsync();
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", "{}");

        (await got.Task.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("signalType").GetString().Should().Be("offer");
        push.Pushed.Should().BeEmpty();
    }

    [Fact]
    public async Task Message_pushes_carry_type_and_conversation()
    {
        var sender = await DeviceAsync();
        var peer = await DeviceAsync();
        var member = await DeviceAsync();
        var created = await sender.Http.PostAsJsonAsync("/groups",
            new { memberDeviceIds = new[] { member.Id } });
        var group = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();
        var (factory, push) = RecordingFactory();
        await using var _f = factory;
        await using var hub = Hub(factory, sender.Token);
        await hub.StartAsync();
        var body = Convert.ToBase64String([1, 2, 3]);

        await hub.InvokeAsync("SendReliableMessage", peer.Id, Guid.NewGuid(), body);
        await hub.InvokeAsync("SendReliableGroupMessage", group, Guid.NewGuid(),
            new Dictionary<Guid, string> { [member.Id] = body });

        push.Pushed.Should().Equal(
            (peer.Id, new PushNotification("message", sender.Id.ToString())),
            (member.Id, new PushNotification("group_message", group.ToString())));
    }
}
