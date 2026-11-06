// ---------------------------------------------------------------------------
// CallRingingTests.cs - Ringing an offline callee (spec 2026-11-06-call-ringing)
// ---------------------------------------------------------------------------
// Real API + PostgreSQL + SignalR, all three push providers configured
// against a fake push service (same seam as PushDeliveryTests), so every
// test sees the exact ring / alert pushes that would leave the server.
// Covers section 1.4: ring path for iOS VoIP and Android ringCalls, legacy
// path for devices without the capability and for a muted conversation,
// delivery of offer + buffered ICE exactly once on connect, caller hangup,
// ring timeout, lock-screen decline, and the business call path.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Hubs;

public class CallRingingTests : IntegrationTestBase
{
    private const string CallId = "5b6c7d8e-1f2a-4b3c-9d4e-0a1b2c3d4e5f";
    private static readonly string VoipToken = new('e', 64);
    private static readonly string AlertToken = new('a', 64);

    private readonly FakePushService _push = new();
    private readonly FakeTimeProvider _clock = new(DateTimeOffset.UtcNow);

    private static string Envelope(string payload, string callId = CallId) =>
        "{\"v\":1,\"callId\":\"" + callId + "\",\"payload\":\"" + payload + "\"}";

    /// <summary>
    /// All providers configured, all talking to <see cref="_push"/>; the
    /// pending call store runs on <see cref="_clock"/> so the ring timeout
    /// can be crossed without waiting 45 s.
    /// </summary>
    private WebApplicationFactory<Program> RingFactory()
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
                    sv.AddHttpClient(name).ConfigurePrimaryHttpMessageHandler(() => _push.CreateHandler());
                sv.AddSingleton(new PendingCallStore(_clock));
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
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var id = body.GetProperty("deviceId").GetGuid();
        var tokenResponse = await Client.PostAsJsonAsync("/auth/token",
            new { deviceId = id, deviceSecret = body.GetProperty("deviceSecret").GetString() });
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
        var http = Factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (id, token, http);
    }

    /// <summary>An iPhone: alert token for messages plus a VoIP token for ringing.</summary>
    private async Task<(Guid Id, string Token, HttpClient Http)> IphoneAsync()
    {
        var d = await DeviceAsync();
        (await d.Http.PutAsJsonAsync($"/devices/{d.Id}/push-token", new { platform = "apns", token = AlertToken }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await d.Http.PutAsJsonAsync($"/devices/{d.Id}/voip-token", new { token = VoipToken }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        return d;
    }

    private async Task<(Guid Id, string Token, HttpClient Http)> AndroidAsync(bool ringCalls, string fcmToken)
    {
        var d = await DeviceAsync();
        (await d.Http.PutAsJsonAsync($"/devices/{d.Id}/push-token",
                new { platform = "fcm", token = fcmToken, ringCalls }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        return d;
    }

    private static HubConnection Hub(WebApplicationFactory<Program> factory, string token) => new HubConnectionBuilder()
        .WithUrl($"{factory.Server.BaseAddress}hub?access_token={token}",
            o => o.HttpMessageHandlerFactory = _ => factory.Server.CreateHandler())
        .Build();

    /// <summary>Records every CallSignal a connection receives, in order.</summary>
    private sealed class SignalLog
    {
        private readonly ConcurrentQueue<JsonElement> _signals = new();
        private readonly SemaphoreSlim _arrived = new(0);

        public SignalLog(HubConnection connection) =>
            connection.On<JsonElement>("CallSignal", s => { _signals.Enqueue(s); _arrived.Release(); });

        public List<JsonElement> All => _signals.ToList();

        public async Task<List<JsonElement>> WaitForAsync(int count)
        {
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (_signals.Count < count && DateTime.UtcNow < deadline)
                await _arrived.WaitAsync(TimeSpan.FromMilliseconds(200));
            _signals.Should().HaveCountGreaterThanOrEqualTo(count);
            return All;
        }
    }

    private static string Type(JsonElement s) => s.GetProperty("signalType").GetString()!;
    private static string Payload(JsonElement s) => s.GetProperty("payload").GetString()!;
    private static Guid Sender(JsonElement s) => s.GetProperty("senderId").GetGuid();

    private List<RecordedRequest> Pushes => _push.Requests.ToList();

    // -----------------------------------------------------------------------
    // Ring path
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Iphone_with_voip_token_rings_and_the_caller_hears_ringing()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var log = new SignalLog(hub);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        var reply = (await log.WaitForAsync(1)).Single();
        Type(reply).Should().Be("ringing");
        Sender(reply).Should().Be(callee.Id);
        Payload(reply).Should().Be(Envelope("v=0"));
        var push = Pushes.Should().ContainSingle("a ring push replaces the alert push, never both").Subject;
        push.Request.RequestUri!.AbsolutePath.Should().Be($"/3/device/{VoipToken}");
        push.Header("apns-push-type").Should().Be("voip");
        push.Header("apns-topic").Should().Be("cz.zcloud.jay.voip");
        push.BodyText.Should().Be("{\"aps\":{},\"type\":\"incoming_call\",\"callId\":\"" + CallId +
                                  "\",\"conversationId\":\"" + caller.Id + "\",\"v\":\"1\"}");
    }

    [Fact]
    public async Task Android_with_ring_calls_gets_a_data_only_ring()
    {
        var caller = await DeviceAsync();
        var callee = await AndroidAsync(ringCalls: true, "ring-token");
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var log = new SignalLog(hub);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        Type((await log.WaitForAsync(1)).Single()).Should().Be("ringing");
        var push = Pushes.Should().ContainSingle().Subject;
        push.Request.RequestUri!.Host.Should().Be("fcm.googleapis.com");
        push.BodyText.Should().NotContain("\"notification\"");
        var data = JsonDocument.Parse(push.BodyText).RootElement.GetProperty("message").GetProperty("data");
        data.GetProperty("type").GetString().Should().Be("incoming_call");
        data.GetProperty("callId").GetString().Should().Be(CallId);
        data.GetProperty("conversationId").GetString().Should().Be(caller.Id.ToString());
    }

    // -----------------------------------------------------------------------
    // Legacy path (R2, R8)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Android_without_ring_calls_keeps_unavailable_and_the_alert_push()
    {
        var caller = await DeviceAsync();
        var callee = await AndroidAsync(ringCalls: false, "old-app-token");
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var log = new SignalLog(hub);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));
        await hub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", Envelope("c"));
        await hub.InvokeAsync("CallSignal", callee.Id, "hangup", Envelope(""));

        Type((await log.WaitForAsync(1)).Single()).Should().Be("unavailable");
        var push = Pushes.Should().ContainSingle().Subject;
        push.BodyText.Should().Contain("\"notification\"").And.Contain("\"channel_id\":\"calls\"");
    }

    [Fact]
    public async Task Offer_without_a_call_envelope_takes_the_legacy_path_even_on_a_ringing_device()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var log = new SignalLog(hub);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", "{\"sdp\":\"x\"}");
        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0", new string('x', 65)));

        (await log.WaitForAsync(2)).Select(Type).Should().Equal("unavailable", "unavailable");
        Pushes.Should().HaveCount(2).And.OnlyContain(p => p.Header("apns-push-type") == "alert");
    }

    [Fact]
    public async Task Muted_conversation_neither_rings_nor_pushes()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        (await callee.Http.PutAsJsonAsync($"/mutes/direct/{caller.Id}", new { mode = "all" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var log = new SignalLog(hub);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        Type((await log.WaitForAsync(1)).Single()).Should().Be("unavailable");
        Pushes.Should().BeEmpty();
        // And nothing waits for the callee either.
        await using var calleeHub = Hub(factory, callee.Token);
        var calleeLog = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        await calleeHub.InvokeAsync("RequestPendingCalls");
        calleeLog.All.Should().BeEmpty();
    }

    // -----------------------------------------------------------------------
    // Delivery, cancel, timeout, decline
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Callee_connect_receives_offer_and_buffered_ice_in_order_exactly_once()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        var other = await DeviceAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var callerLog = new SignalLog(hub);
        await hub.StartAsync();
        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));
        await hub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", Envelope("c1"));
        await hub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", Envelope("c2"));
        // Another device's ICE with the same callId is not part of this call.
        await using (var otherHub = Hub(factory, other.Token))
        {
            await otherHub.StartAsync();
            await otherHub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", Envelope("foreign"));
        }

        await using var calleeHub = Hub(factory, callee.Token);
        var log = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        var got = await log.WaitForAsync(3);
        // Idempotent: a late RequestPendingCalls delivers nothing twice.
        await calleeHub.InvokeAsync("RequestPendingCalls");
        await Task.Delay(300);

        log.All.Should().HaveCount(3);
        got.Select(Type).Should().Equal("offer", "ice-candidate", "ice-candidate");
        got.Select(Payload).Should().Equal(Envelope("v=0"), Envelope("c1"), Envelope("c2"));
        got.Should().OnlyContain(s => Sender(s) == caller.Id);
        got.Should().OnlyContain(s => s.GetProperty("businessGroupId").ValueKind == JsonValueKind.Null);

        // From now on the call is live: signals are relayed directly.
        await hub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", Envelope("c3"));
        Payload((await log.WaitForAsync(4))[3]).Should().Be(Envelope("c3"));
        callerLog.All.Select(Type).Should().Equal("ringing");
    }

    [Fact]
    public async Task Caller_hangup_cancels_the_ring_with_a_push_and_a_cancelled_signal()
    {
        var caller = await DeviceAsync();
        var callee = await AndroidAsync(ringCalls: true, "ring-token");
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));
        await hub.InvokeAsync("CallSignal", callee.Id, "hangup", Envelope(""));
        // A retried hangup does not push again.
        await hub.InvokeAsync("CallSignal", callee.Id, "hangup", Envelope(""));

        Pushes.Select(p => JsonDocument.Parse(p.BodyText).RootElement.GetProperty("message")
                .GetProperty("data").GetProperty("type").GetString())
            .Should().Equal("incoming_call", "call_cancelled");
        Pushes[1].BodyText.Should().Contain($"\"callId\":\"{CallId}\"")
            .And.Contain($"\"conversationId\":\"{caller.Id}\"").And.NotContain("\"notification\"");

        await using var calleeHub = Hub(factory, callee.Token);
        var log = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        var cancelled = (await log.WaitForAsync(1)).Single();
        await calleeHub.InvokeAsync("RequestPendingCalls");
        await Task.Delay(300);

        log.All.Should().HaveCount(1, "no offer for a cancelled call, and the tombstone is delivered once");
        Type(cancelled).Should().Be("cancelled");
        Sender(cancelled).Should().Be(caller.Id);
        Payload(cancelled).Should().Be(Envelope(""));
    }

    [Fact]
    public async Task Iphone_gets_no_extra_push_when_the_caller_hangs_up()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));
        await hub.InvokeAsync("CallSignal", callee.Id, "hangup", Envelope(""));

        Pushes.Should().ContainSingle().Which.Header("apns-push-type").Should().Be("voip");
    }

    [Fact]
    public async Task Ring_timeout_leaves_a_cancelled_signal_for_the_callee()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();
        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        _clock.Advance(PendingCallStore.RingTimeout + TimeSpan.FromSeconds(1));
        // A late ICE of the dead call is dropped, not buffered.
        await hub.InvokeAsync("CallSignal", callee.Id, "ice-candidate", Envelope("late"));

        await using var calleeHub = Hub(factory, callee.Token);
        var log = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        var got = await log.WaitForAsync(1);
        await calleeHub.InvokeAsync("RequestPendingCalls");
        await Task.Delay(300);

        log.All.Should().HaveCount(1);
        Type(got[0]).Should().Be("cancelled");
        Payload(got[0]).Should().Be(Envelope(""));
    }

    [Fact]
    public async Task Decline_tells_the_caller_and_leaves_nothing_for_the_callee()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var callerLog = new SignalLog(hub);
        await hub.StartAsync();
        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        // The app connects to decline; that connect already delivers the
        // offer, the decline must still reach the caller.
        await using (var declining = Hub(factory, callee.Token))
        {
            await declining.StartAsync();
            await declining.InvokeAsync("DeclinePendingCall", CallId);
            await declining.InvokeAsync("DeclinePendingCall", CallId);
        }

        var got = await callerLog.WaitForAsync(2);
        await Task.Delay(300);
        callerLog.All.Should().HaveCount(2, "a repeated decline is a no-op");
        Type(got[1]).Should().Be("hangup");
        Sender(got[1]).Should().Be(callee.Id);
        Payload(got[1]).Should().Be(Envelope("declined"));

        await using var calleeHub = Hub(factory, callee.Token);
        var log = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        await calleeHub.InvokeAsync("RequestPendingCalls");
        await Task.Delay(300);
        log.All.Should().BeEmpty();
    }

    [Fact]
    public async Task Declining_another_call_id_changes_nothing()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var callerLog = new SignalLog(hub);
        await hub.StartAsync();
        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        await using var calleeHub = Hub(factory, callee.Token);
        await calleeHub.StartAsync();
        await calleeHub.InvokeAsync("DeclinePendingCall", "not-this-call");
        await calleeHub.InvokeAsync("DeclinePendingCall", new string('x', 65));
        await Task.Delay(300);

        callerLog.All.Select(Type).Should().Equal("ringing");
    }

    // -----------------------------------------------------------------------
    // Business calls (H1) keep their policy checks on the ring path
    // -----------------------------------------------------------------------

    private async Task<Guid> BusinessGroupAsync(Guid a, Guid b)
    {
        var auditor = await DeviceAsync();
        Guid organizationId;
        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
            org.AuditorDeviceId = auditor.Id;
            auditDb.Organizations.Add(org);
            await auditDb.SaveChangesAsync();
            organizationId = org.OrganizationId;
        }
        var group = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = a, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = a, Role = "admin" },
                new GroupMember { GroupId = group, DeviceId = b, Role = "member" },
                new GroupMember { GroupId = group, DeviceId = auditor.Id, Role = "auditor" });
            await db.SaveChangesAsync();
        }
        return group;
    }

    [Fact]
    public async Task Business_call_rings_and_carries_the_group_through_delivery_and_decline()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        var group = await BusinessGroupAsync(caller.Id, callee.Id);
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        var callerLog = new SignalLog(hub);
        await hub.StartAsync();

        await hub.InvokeAsync("BusinessCallSignal", callee.Id, "offer", Envelope("v=0"), group);
        await hub.InvokeAsync("BusinessCallSignal", callee.Id, "ice-candidate", Envelope("c1"), group);

        var ringing = (await callerLog.WaitForAsync(1)).Single();
        Type(ringing).Should().Be("ringing");
        ringing.GetProperty("businessGroupId").GetGuid().Should().Be(group);
        Pushes.Should().ContainSingle().Which.BodyText.Should().Contain($"\"conversationId\":\"{group}\"");

        await using var calleeHub = Hub(factory, callee.Token);
        var log = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        var got = await log.WaitForAsync(2);
        got.Select(Type).Should().Equal("offer", "ice-candidate");
        got.Should().OnlyContain(s => s.GetProperty("businessGroupId").GetGuid() == group);

        await calleeHub.InvokeAsync("DeclinePendingCall", CallId);
        var declined = (await callerLog.WaitForAsync(2))[1];
        Type(declined).Should().Be("hangup");
        declined.GetProperty("businessGroupId").GetGuid().Should().Be(group);
    }

    [Fact]
    public async Task Business_call_from_a_non_member_is_rejected_before_anything_rings()
    {
        var member = await DeviceAsync();
        var callee = await IphoneAsync();
        var outsider = await DeviceAsync();
        var group = await BusinessGroupAsync(member.Id, callee.Id);
        await using var factory = RingFactory();
        await using var hub = Hub(factory, outsider.Token);
        await hub.StartAsync();

        var send = () => hub.InvokeAsync("BusinessCallSignal", callee.Id, "offer", Envelope("v=0"), group);

        await send.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>()
            .Where(e => e.Message.Contains("not_a_business_member"));
        Pushes.Should().BeEmpty();
        await using var calleeHub = Hub(factory, callee.Token);
        var log = new SignalLog(calleeHub);
        await calleeHub.StartAsync();
        await calleeHub.InvokeAsync("RequestPendingCalls");
        log.All.Should().BeEmpty();
    }

    // -----------------------------------------------------------------------
    // Dead VoIP token
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Dead_voip_token_is_cleared_but_the_alert_token_stays()
    {
        var caller = await DeviceAsync();
        var callee = await IphoneAsync();
        _push.Respond = _ => new HttpResponseMessage(HttpStatusCode.Gone)
            { Content = new StringContent("{\"reason\":\"Unregistered\"}") };
        await using var factory = RingFactory();
        await using var hub = Hub(factory, caller.Token);
        await hub.StartAsync();

        await hub.InvokeAsync("CallSignal", callee.Id, "offer", Envelope("v=0"));

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var device = db.Devices.Single(d => d.DeviceId == callee.Id);
        device.VoipPushToken.Should().BeNull();
        device.PushToken.Should().Be(AlertToken);
    }
}
