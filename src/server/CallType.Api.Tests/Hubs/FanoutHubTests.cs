// ---------------------------------------------------------------------------
// FanoutHubTests.cs - multi-device fan-out and link relay on MessengerHub
// ---------------------------------------------------------------------------
// Device lists are seeded straight into the database: signature checking is
// the clients' job, the hub only routes by the stored membership.
// ---------------------------------------------------------------------------

using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using Microsoft.Extensions.Logging;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Hubs;

public class FanoutHubTests : IntegrationTestBase
{
    private static readonly string Body = Convert.ToBase64String([1, 2, 3]);

    private HubConnection Hub(string token) => new HubConnectionBuilder()
        .WithUrl($"{Factory.Server.BaseAddress}hub?access_token={token}",
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

    private async Task<List<Guid>> QueuedForAsync(Guid messageId)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.QueuedMessages.Where(m => m.MessageId == messageId).Select(m => m.RecipientId).ToListAsync();
    }

    private static Dictionary<Guid, string> Payloads(params Guid[] ids) => ids.ToDictionary(id => id, _ => Body);

    [Fact]
    public async Task Direct_fanout_reaches_every_device_of_both_identities()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();

        var messageId = Guid.NewGuid();
        var targets = new[] { bPhone.DeviceId, bWeb.DeviceId, aPhone.DeviceId };
        // Sent from A's COMPANION: its own primary is a required recipient too.
        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, messageId, targets, Payloads(targets));

        (await QueuedForAsync(messageId)).Should().BeEquivalentTo(targets);
    }

    [Fact]
    public async Task Missing_or_extra_device_is_stale_and_names_the_required_set()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        var stranger = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();

        var missing = new[] { bPhone.DeviceId };
        var tooFew = await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, messageId, missing, Payloads(missing)))
            .Should().ThrowAsync<HubException>();
        tooFew.Which.Message.Should().Contain("device_list_stale:")
            .And.Contain(bPhone.DeviceId.ToString()).And.Contain(bWeb.DeviceId.ToString());

        var extra = new[] { bPhone.DeviceId, bWeb.DeviceId, stranger.DeviceId };
        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, messageId, extra, Payloads(extra)))
            .Should().ThrowAsync<HubException>().WithMessage("*device_list_stale:*");

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task A_large_send_may_be_split_but_never_leaves_the_declared_set()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        var stranger = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var all = new[] { bPhone.DeviceId, bWeb.DeviceId };

        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, messageId, all, Payloads(bPhone.DeviceId));
        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, messageId, all, Payloads(bWeb.DeviceId));
        (await QueuedForAsync(messageId)).Should().BeEquivalentTo(all);

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, Guid.NewGuid(), all, Payloads(stranger.DeviceId)))
            .Should().ThrowAsync<HubException>();
    }

    [Fact]
    public async Task Recipient_must_be_a_primary()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var all = new[] { bPhone.DeviceId, bWeb.DeviceId };
        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bWeb.DeviceId, Guid.NewGuid(), all, Payloads(all)))
            .Should().ThrowAsync<HubException>().WithMessage("*recipient_is_not_primary*");
    }

    [Fact]
    public async Task Group_fanout_covers_companions_of_members_and_sender()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        var groupId = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = groupId, CreatedBy = aPhone.DeviceId, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = aPhone.DeviceId, Role = "admin", JoinedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = bPhone.DeviceId, Role = "member", JoinedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync();
        }
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var targets = new[] { aPhone.DeviceId, bPhone.DeviceId, bWeb.DeviceId };

        // A's companion is not a GroupMember row; it sends on behalf of its identity.
        await hub.InvokeAsync("SendReliableGroupFanout", groupId, messageId, targets, Payloads(targets));

        (await QueuedForAsync(messageId)).Should().BeEquivalentTo(targets);
    }

    // Organization with RequireBusinessConversations and the given PRIMARY devices
    // enrolled (companions are never enrolled, which is the point of the tests).
    private async Task EnrollAsync(params Guid[] devices)
    {
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
        org.SetRequireBusinessConversations(true);
        auditDb.Organizations.Add(org);
        foreach (var device in devices)
            auditDb.OrgEnrollments.Add(OrgEnrollment.Enroll(
                new OrgInvite(Guid.NewGuid(), org.OrganizationId, Guid.NewGuid().ToString(), Guid.NewGuid(), DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddDays(1)),
                device, Guid.Empty, DateTimeOffset.UtcNow));
        await auditDb.SaveChangesAsync();
    }

    [Fact]
    public async Task Companion_of_an_enrolled_employee_cannot_fan_out_around_the_business_policy()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        await EnrollAsync(aPhone.DeviceId, bPhone.DeviceId);
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var targets = new[] { bPhone.DeviceId, aPhone.DeviceId };

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, messageId, targets, Payloads(targets)))
            .Should().ThrowAsync<HubException>().WithMessage("*business_conversation_required*");

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task Companion_of_an_enrolled_employee_cannot_use_the_legacy_send_around_the_policy()
    {
        // The bypass being closed: OrgEnrollments holds primaries only, so
        // the old methods saw a companion as an unenrolled outsider.
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        await EnrollAsync(aPhone.DeviceId, bPhone.DeviceId);
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableMessage", bPhone.DeviceId, messageId, Body))
            .Should().ThrowAsync<HubException>().WithMessage("*business_conversation_required*");

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task Group_fanout_is_refused_in_a_business_group()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var groupId = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = groupId, CreatedBy = aPhone.DeviceId, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = Guid.NewGuid() });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = aPhone.DeviceId, Role = "admin", JoinedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = bPhone.DeviceId, Role = "member", JoinedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync();
        }
        await using var hub = Hub(aPhone.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var targets = new[] { bPhone.DeviceId };

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableGroupFanout", groupId, messageId, targets, Payloads(targets)))
            .Should().ThrowAsync<HubException>().WithMessage("*fanout_unsupported_in_business_group*");

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task Companion_whose_primary_is_not_a_group_member_is_rejected()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        var groupId = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = groupId, CreatedBy = bPhone.DeviceId, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = bPhone.DeviceId, Role = "admin", JoinedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync();
        }
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var targets = new[] { bPhone.DeviceId };

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableGroupFanout", groupId, messageId, targets, Payloads(targets)))
            .Should().ThrowAsync<HubException>().WithMessage("*group members*");

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task One_invalid_payload_queues_nothing_for_the_other_devices()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var all = new[] { bPhone.DeviceId, bWeb.DeviceId };
        var payloads = new Dictionary<Guid, string> { [bPhone.DeviceId] = Body, [bWeb.DeviceId] = "not base64!!" };

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, messageId, all, payloads))
            .Should().ThrowAsync<HubException>();

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task Link_offer_and_consent_are_relayed_and_an_offline_target_is_reported()
    {
        var phone = await RegisterAndAuthenticateAsync();
        var web = await RegisterAndAuthenticateAsync();
        await using var phoneHub = Hub(phone.Token);
        await using var webHub = Hub(web.Token);
        var offer = new TaskCompletionSource<JsonElement>();
        var consent = new TaskCompletionSource<JsonElement>();
        webHub.On<JsonElement>("LinkOffer", offer.SetResult);
        phoneHub.On<JsonElement>("LinkConsent", consent.SetResult);
        await phoneHub.StartAsync();

        await FluentActions.Awaiting(() => phoneHub.InvokeAsync("LinkOffer", web.DeviceId))
            .Should().ThrowAsync<HubException>().WithMessage("*link_target_offline*");

        await webHub.StartAsync();
        // SignalR runs OnConnectedAsync (which puts the device into the online
        // map) before it dispatches the connection's first invocation, so a
        // completed round trip on the web connection proves it is online.
        // Without it, the offer below could overtake the registration.
        await webHub.InvokeAsync("RequestPendingMessages");
        await phoneHub.InvokeAsync("LinkOffer", web.DeviceId);
        var offered = await offer.Task.WaitAsync(TimeSpan.FromSeconds(5));
        offered.GetProperty("primaryDeviceId").GetGuid().Should().Be(phone.DeviceId);
        // Looked up by the server, so the new device can show whose phone asks.
        offered.GetProperty("userHandle").GetString().Should().Be(phone.UserHandle);

        await webHub.InvokeAsync("LinkConsent", phone.DeviceId, "c2ln");
        var received = await consent.Task.WaitAsync(TimeSpan.FromSeconds(5));
        received.GetProperty("deviceId").GetGuid().Should().Be(web.DeviceId);
        received.GetProperty("consentSig").GetString().Should().Be("c2ln");
        Factory.Services.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>()
            .TryGetValue(CallType.Api.Endpoints.DeviceListEndpoints.ConsentKey(web.DeviceId, phone.DeviceId), out _)
            .Should().BeTrue();
    }

    // Records push targets instead of calling FCM: the smallest seam to
    // observe who the hub tries to wake (SendPushAsync is virtual for this).
    private sealed class RecordingPush(IHttpClientFactory h, IServiceScopeFactory sf,
        FcmTokenProvider t, ILogger<PushNotificationService> l) : PushNotificationService(h, sf, t, l)
    {
        public readonly System.Collections.Concurrent.ConcurrentBag<Guid> Pushed = new();
        public override Task SendPushAsync(Guid recipientDeviceId) { Pushed.Add(recipientDeviceId); return Task.CompletedTask; }
    }

    [Fact]
    public async Task Fanout_event_carries_senderPrimaryId_live_and_replayed()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var loner = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);

        // Live: bPhone is connected when the companion aWeb sends.
        await using var bHub = Hub(bPhone.Token);
        var live = new TaskCompletionSource<JsonElement>();
        bHub.On<JsonElement>("ReceiveMessage", e => live.TrySetResult(e));
        await bHub.StartAsync();
        await using var aHub = Hub(aWeb.Token);
        await aHub.StartAsync();
        var m1 = Guid.NewGuid();
        var toB = new[] { bPhone.DeviceId, aPhone.DeviceId };
        await aHub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, m1, toB, Payloads(toB));
        var ev = await live.Task.WaitAsync(TimeSpan.FromSeconds(5));
        ev.GetProperty("senderId").GetGuid().Should().Be(aWeb.DeviceId);
        ev.GetProperty("senderPrimaryId").GetGuid().Should().Be(aPhone.DeviceId);

        // Replayed: a standalone sender writes while the recipient is offline.
        await using var lonerHub = Hub(loner.Token);
        await lonerHub.StartAsync();
        var m2 = Guid.NewGuid();
        var toLoner = new[] { bPhone.DeviceId };
        await bHub.StopAsync();
        await lonerHub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, m2, toLoner, Payloads(toLoner));
        var replay = new TaskCompletionSource<JsonElement>();
        await using var bHub2 = Hub(bPhone.Token);
        bHub2.On<JsonElement>("ReceiveMessage", e =>
        {
            if (e.GetProperty("messageId").GetGuid() == m2) replay.TrySetResult(e);
        });
        await bHub2.StartAsync();
        var replayed = await replay.Task.WaitAsync(TimeSpan.FromSeconds(5));
        replayed.GetProperty("senderPrimaryId").GetGuid().Should().Be(loner.DeviceId);
    }

    [Fact]
    public async Task Fanout_pushes_other_identities_but_not_the_senders_own_devices()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        var push = new RecordingPush(
            Factory.Services.GetRequiredService<IHttpClientFactory>(),
            Factory.Services.GetRequiredService<IServiceScopeFactory>(),
            Factory.Services.GetRequiredService<FcmTokenProvider>(),
            Factory.Services.GetRequiredService<ILogger<PushNotificationService>>());
        await using var factory = Factory.WithWebHostBuilder(b =>
            b.ConfigureServices(sv => sv.AddSingleton<PushNotificationService>(push)));
        await using var hub = new HubConnectionBuilder()
            .WithUrl($"{factory.Server.BaseAddress}hub?access_token={aWeb.Token}",
                o => o.HttpMessageHandlerFactory = _ => factory.Server.CreateHandler())
            .Build();
        await hub.StartAsync();

        // Everyone except the sender is offline, so every copy would be pushed.
        var targets = new[] { bPhone.DeviceId, aPhone.DeviceId };
        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, Guid.NewGuid(), targets, Payloads(targets));

        push.Pushed.Should().BeEquivalentTo(new[] { bPhone.DeviceId });
    }
}
