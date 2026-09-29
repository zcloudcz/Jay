// ---------------------------------------------------------------------------
// MessengerHubQuietMessageTests.cs — X0-M-1 quiet send + push seam (X0-S)
// ---------------------------------------------------------------------------
// SendQuietMessage / SendQuietGroupMessage must behave exactly like the
// reliable methods (queue, idempotence, KB2, P1) except that no push is ever
// sent. The push side is observed through a recording double of
// IPushNotificationService registered in DI; the DATABASE is the real
// Testcontainers PostgreSQL (project rule: never mock the DB).
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.AspNetCore.TestHost;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Hubs;

public class MessengerHubQuietMessageTests : IntegrationTestBase
{
    /// <summary>Records every call the hub makes on the push seam.</summary>
    private sealed class RecordingPushService : IPushNotificationService
    {
        public ConcurrentQueue<(Guid Recipient, Guid Sender, Guid MessageId, Guid? GroupId)> MessagePushes { get; } = new();
        public ConcurrentQueue<(Guid Recipient, Guid Sender, Guid MessageId, Guid? GroupId)> UnackedChecks { get; } = new();

        public Task SendPushAsync(Guid recipientDeviceId) => Task.CompletedTask;

        public Task SendMessagePushAsync(Guid recipientDeviceId, Guid senderDeviceId, Guid messageId, Guid? groupId)
        {
            MessagePushes.Enqueue((recipientDeviceId, senderDeviceId, messageId, groupId));
            return Task.CompletedTask;
        }

        public void ScheduleUnackedPushCheck(Guid recipientDeviceId, Guid senderDeviceId, Guid messageId, Guid? groupId)
            => UnackedChecks.Enqueue((recipientDeviceId, senderDeviceId, messageId, groupId));

        public Task SendChannelPostPushAsync(Guid channelId, TimeSpan throttleWindow, Func<Guid, bool> isOnline)
            => Task.CompletedTask;
    }

    private readonly RecordingPushService _push = new();
    private WebApplicationFactory<Program>? _factory;

    // Same containers/config as the base factory, only the push seam replaced.
    private WebApplicationFactory<Program> PushFactory => _factory ??= Factory.WithWebHostBuilder(b =>
        b.ConfigureTestServices(services =>
        {
            services.RemoveAll<IPushNotificationService>();
            services.AddSingleton<IPushNotificationService>(_push);
        }));

    private async Task<(Guid DeviceId, string Token)> RegisterDeviceAsync()
    {
        using var client = PushFactory.CreateClient();
        var reg = await client.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06])
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = body.GetProperty("deviceId").GetGuid();
        var token = await client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret = body.GetProperty("deviceSecret").GetString()
        });
        token.StatusCode.Should().Be(HttpStatusCode.OK);
        return (deviceId, (await token.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!);
    }

    private HubConnection Connect(string token)
    {
        var server = PushFactory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={token}",
                o => o.HttpMessageHandlerFactory = _ => server.CreateHandler())
            .Build();
    }

    private async Task<int> QueuedCountAsync(Guid messageId, Guid? recipient = null)
    {
        using var scope = PushFactory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.QueuedMessages.AsNoTracking()
            .CountAsync(m => m.MessageId == messageId && (recipient == null || m.RecipientId == recipient));
    }

    [Fact]
    public async Task Quiet_message_to_offline_recipient_is_queued_without_push()
    {
        var (sender, senderToken) = await RegisterDeviceAsync();
        var (recipient, _) = await RegisterDeviceAsync();
        await using var connection = Connect(senderToken);
        await connection.StartAsync();
        var id = Guid.NewGuid();

        await connection.InvokeAsync("SendQuietMessage", recipient, id, "AQI=");
        // Same id again: idempotent on (recipient, sender, messageId) like the reliable path.
        await connection.InvokeAsync("SendQuietMessage", recipient, id, "AQI=");

        (await QueuedCountAsync(id, recipient)).Should().Be(1);
        _push.MessagePushes.Should().BeEmpty("a control message must never wake the device");
        _push.UnackedChecks.Should().BeEmpty();
    }

    [Fact]
    public async Task Reliable_message_to_offline_recipient_still_pushes_with_full_metadata()
    {
        var (sender, senderToken) = await RegisterDeviceAsync();
        var (recipient, _) = await RegisterDeviceAsync();
        await using var connection = Connect(senderToken);
        await connection.StartAsync();
        var id = Guid.NewGuid();

        await connection.InvokeAsync("SendReliableMessage", recipient, id, "AQI=");

        _push.MessagePushes.Should().ContainSingle().Which.Should().Be((recipient, sender, id, (Guid?)null));
    }

    [Fact]
    public async Task Online_recipient_gets_an_unacked_check_only_for_the_reliable_path()
    {
        var (_, senderToken) = await RegisterDeviceAsync();
        var (recipient, recipientToken) = await RegisterDeviceAsync();
        await using var sending = Connect(senderToken);
        await using var receiving = Connect(recipientToken);
        var received = new ConcurrentQueue<Guid>();
        receiving.On<JsonElement>("ReceiveMessage", m => received.Enqueue(m.GetProperty("messageId").GetGuid()));
        await sending.StartAsync();
        await receiving.StartAsync();
        var quietId = Guid.NewGuid();
        var reliableId = Guid.NewGuid();

        await sending.InvokeAsync("SendQuietMessage", recipient, quietId, "AQI=");
        await sending.InvokeAsync("SendReliableMessage", recipient, reliableId, "AQI=");

        // Both are delivered live — "quiet" only changes pushing, not delivery.
        // Distinct: delivery is at-least-once. The client's StartAsync returns
        // after the handshake, possibly before OnConnectedAsync has drained the
        // queue, so an unacked message can legitimately arrive twice (live +
        // replay); the client dedupes by messageId.
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (received.Distinct().Count() < 2 && DateTime.UtcNow < deadline) await Task.Delay(50);
        received.Distinct().Should().BeEquivalentTo([quietId, reliableId]);
        _push.UnackedChecks.Select(c => c.MessageId).Should().Equal(reliableId);
        _push.MessagePushes.Should().BeEmpty();
    }

    [Fact]
    public async Task Quiet_group_message_is_queued_for_offline_members_without_push()
    {
        var (sender, senderToken) = await RegisterDeviceAsync();
        var (a, _) = await RegisterDeviceAsync();
        var (b, _) = await RegisterDeviceAsync();
        var group = Guid.NewGuid();
        using (var scope = PushFactory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = sender, Role = "admin" },
                new GroupMember { GroupId = group, DeviceId = a, Role = "member" },
                new GroupMember { GroupId = group, DeviceId = b, Role = "member" });
            await db.SaveChangesAsync();
        }
        await using var connection = Connect(senderToken);
        await connection.StartAsync();
        var id = Guid.NewGuid();

        await connection.InvokeAsync("SendQuietGroupMessage", group, id,
            new Dictionary<Guid, string> { [a] = "AQI=", [b] = "AQI=" });

        (await QueuedCountAsync(id)).Should().Be(2);
        _push.MessagePushes.Should().BeEmpty();

        // Control: the reliable group path to the same offline members pushes both.
        var reliableId = Guid.NewGuid();
        await connection.InvokeAsync("SendReliableGroupMessage", group, reliableId,
            new Dictionary<Guid, string> { [a] = "AQI=", [b] = "AQI=" });
        _push.MessagePushes.Select(p => (p.Recipient, p.GroupId)).Should()
            .BeEquivalentTo(new[] { (a, (Guid?)group), (b, (Guid?)group) });
    }

    [Fact]
    public async Task Quiet_business_group_message_without_auditor_payload_is_rejected()
    {
        // KB2 applies to the quiet path too: an edit/delete/reaction in a
        // business group must reach the archive like any other message.
        var (sender, senderToken) = await RegisterDeviceAsync();
        var (recipient, _) = await RegisterDeviceAsync();
        var (auditor, auditorToken) = await RegisterDeviceAsync();
        var group = Guid.NewGuid();
        using (var scope = PushFactory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
            org.AuditorDeviceId = auditor;
            auditDb.Organizations.Add(org);
            await auditDb.SaveChangesAsync();

            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = org.OrganizationId });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = sender, Role = "admin" },
                new GroupMember { GroupId = group, DeviceId = recipient, Role = "member" },
                new GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
            await db.SaveChangesAsync();
        }
        await using var sending = Connect(senderToken);
        // Auditor connected (alive), so the check under test is KB2, not W2-F.
        await using var auditing = Connect(auditorToken);
        await sending.StartAsync();
        await auditing.StartAsync();
        var id = Guid.NewGuid();

        var send = () => sending.InvokeAsync("SendQuietGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=" });

        (await send.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>()).Which.Message
            .Should().Contain("audit_recipient_missing");
        (await QueuedCountAsync(id)).Should().Be(0);
    }

    [Fact]
    public async Task Both_push_seams_resolve_to_the_same_singleton_in_production_wiring()
    {
        // Base factory (no override): the hub/ChannelService seam and the call
        // seam must share one instance, so FCM token cache and throttle are shared.
        var messages = Factory.Services.GetRequiredService<IPushNotificationService>();
        var calls = Factory.Services.GetRequiredService<ICallPushSender>();
        messages.Should().BeSameAs(calls).And.BeSameAs(Factory.Services.GetRequiredService<PushNotificationService>());

        // X0 stub: no call push is possible yet, so the hub keeps answering "unavailable".
        (await calls.SendCallPushAsync(Guid.NewGuid(),
                new CallPush(Guid.NewGuid(), Guid.NewGuid(), false, "token", DateTimeOffset.UtcNow.AddSeconds(45)),
                CancellationToken.None))
            .Should().Be(CallPushResult.NotConfigured);
    }
}
