// ---------------------------------------------------------------------------
// FanoutHubTests.cs — multi-device fan-out and link relay on MessengerHub
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
using CallType.Api.Tests.TestFixtures;

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
        await phoneHub.InvokeAsync("LinkOffer", web.DeviceId);
        (await offer.Task.WaitAsync(TimeSpan.FromSeconds(5)))
            .GetProperty("primaryDeviceId").GetGuid().Should().Be(phone.DeviceId);

        await webHub.InvokeAsync("LinkConsent", phone.DeviceId, "c2ln");
        var received = await consent.Task.WaitAsync(TimeSpan.FromSeconds(5));
        received.GetProperty("deviceId").GetGuid().Should().Be(web.DeviceId);
        received.GetProperty("consentSig").GetString().Should().Be("c2ln");
        Factory.Services.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>()
            .TryGetValue(CallType.Api.Endpoints.DeviceListEndpoints.ConsentKey(web.DeviceId, phone.DeviceId), out _)
            .Should().BeTrue();
    }
}
