// ---------------------------------------------------------------------------
// MessengerHubTests.cs — Integration tests for the SignalR MessengerHub
// ---------------------------------------------------------------------------
// Tests the real-time message relay, queued message delivery on connect,
// typing indicators, and WebRTC call signaling. Each test spins up a real
// PostgreSQL instance via Testcontainers and connects SignalR clients through
// the test server's in-process handler — no network sockets needed.
//
// Key challenge: MessengerHub uses a static ConcurrentDictionary to track
// online devices. Since all tests run in the same process, each test uses
// unique random deviceIds to avoid cross-test interference.
//
// Authentication: The hub now requires JWT. Each test registers a device,
// obtains a token, and passes it as access_token query parameter during the
// WebSocket upgrade — the same mechanism real clients use.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Hubs;

public class MessengerHubTests : IntegrationTestBase
{
    // Reusable key material for device registration.
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    /// <summary>
    /// Registers a device and obtains a JWT token for it. Returns the deviceId
    /// and token needed to connect to the SignalR hub.
    /// </summary>
    private async Task<(Guid DeviceId, string Token)> RegisterDeviceAndGetTokenAsync()
    {
        // Use a fresh HttpClient to avoid polluting the shared Client's auth header.
        using var client = Factory.CreateClient();

        var regResponse = await client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });
        regResponse.StatusCode.Should().Be(HttpStatusCode.Created);

        var regBody = await regResponse.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = Guid.Parse(regBody.GetProperty("deviceId").GetString()!);
        var deviceSecret = regBody.GetProperty("deviceSecret").GetString()!;

        var tokenResponse = await client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret
        });
        tokenResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var tokenBody = await tokenResponse.Content.ReadFromJsonAsync<JsonElement>();
        var token = tokenBody.GetProperty("token").GetString()!;

        return (deviceId, token);
    }

    /// <summary>
    /// Builds a SignalR HubConnection that connects through the test server's
    /// in-process HTTP handler with JWT authentication. The access_token query
    /// parameter is extracted by the JwtBearerEvents.OnMessageReceived handler
    /// in Program.cs — same mechanism as production WebSocket connections.
    /// </summary>
    private HubConnection CreateHubConnection(Guid deviceId, string accessToken)
    {
        var server = Factory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={accessToken}", options =>
            {
                // Route HTTP requests through the test server's in-process handler
                // instead of opening real network connections.
                options.HttpMessageHandlerFactory = _ => server.CreateHandler();
            })
            .Build();
    }

    /// <summary>
    /// Creates a real Organization row (AuditorLivenessService looks it up by
    /// id, W2-F) with the given device as its auditor. Business-group hub
    /// tests use a Group.OrganizationId that must resolve to an actual
    /// Organization, or the new fail-closed check treats the org as dead.
    /// </summary>
    private async Task<Guid> CreateBusinessOrganizationAsync(Guid auditorDeviceId)
    {
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
        org.AuditorDeviceId = auditorDeviceId;
        auditDb.Organizations.Add(org);
        await auditDb.SaveChangesAsync();
        return org.OrganizationId;
    }

    [Fact]
    public async Task Client_connects_and_receives_queued_messages()
    {
        // Arrange — register a device and get token for the recipient.
        var (recipientId, recipientToken) = await RegisterDeviceAndGetTokenAsync();
        var senderId = Guid.NewGuid();
        var messageBody = new byte[] { 0xDE, 0xAD, 0xBE, 0xEF };

        // Enqueue a message directly in the DB before the recipient connects.
        // This simulates the "device was offline, messages accumulated" scenario.
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.QueuedMessages.Add(new QueuedMessage
            {
                RecipientId = recipientId,
                SenderId = senderId,
                EncryptedBody = messageBody,
                CreatedAt = DateTimeOffset.UtcNow,
                ExpiresAt = DateTimeOffset.UtcNow.AddDays(30)
            });
            await db.SaveChangesAsync();
        }

        // Set up a TaskCompletionSource to capture the ReceiveMessage callback.
        // SignalR delivers messages asynchronously, so we need to wait for the
        // callback to fire rather than polling.
        var receivedTcs = new TaskCompletionSource<JsonElement>();

        await using var connection = CreateHubConnection(recipientId, recipientToken);
        connection.On<JsonElement>("ReceiveMessage", msg =>
        {
            receivedTcs.TrySetResult(msg);
        });

        // Act — connect triggers OnConnectedAsync which dequeues pending messages.
        await connection.StartAsync();

        // Assert — the queued message should arrive via the ReceiveMessage callback.
        var received = await receivedTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));

        received.GetProperty("senderId").GetString().Should()
            .Be(senderId.ToString(), "the message should identify its sender");

        // The hub converts byte[] to base64 when delivering queued messages.
        var bodyBase64 = received.GetProperty("encryptedBody").GetString();
        Convert.FromBase64String(bodyBase64!).Should()
            .BeEquivalentTo(messageBody, "the encrypted body must round-trip through the queue");

        // Delivery retains ciphertext until the recipient confirms persistence.
        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var remaining = await verifyDb.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .CountAsync();
        remaining.Should().Be(1, "delivery must wait for recipient acknowledgement");

        await connection.StopAsync();
    }

    [Fact]
    public async Task SendMessage_to_online_recipient_delivers_directly()
    {
        // Arrange — two devices connect to the hub with JWT auth.
        var (deviceA, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (deviceB, tokenB) = await RegisterDeviceAndGetTokenAsync();

        var receivedTcs = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA, tokenA);
        await using var connectionB = CreateHubConnection(deviceB, tokenB);

        // Client B listens for incoming messages.
        connectionB.On<JsonElement>("ReceiveMessage", msg =>
        {
            receivedTcs.TrySetResult(msg);
        });

        // Both clients must be connected before sending.
        await connectionA.StartAsync();
        await connectionB.StartAsync();

        // Act — Client A sends an encrypted message to Client B.
        var payload = Convert.ToBase64String(new byte[] { 0x01, 0x02, 0x03 });
        await connectionA.InvokeAsync("SendMessage", deviceB, payload);

        // Assert — Client B should receive the message directly.
        var received = await receivedTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));

        received.GetProperty("senderId").GetString().Should().Be(deviceA.ToString());
        // For online delivery, the hub passes base64 through as-is (no decode/re-encode).
        received.GetProperty("encryptedBody").GetString().Should().Be(payload);

        // Online messages are durable too, until acknowledged.
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var queued = await db.QueuedMessages
            .Where(m => m.RecipientId == deviceB && m.SenderId == deviceA)
            .CountAsync();
        queued.Should().Be(1, "online delivery must also persist until acknowledgement");

        await connectionA.StopAsync();
        await connectionB.StopAsync();
    }

    [Fact]
    public async Task SendMessage_to_offline_recipient_queues_message()
    {
        // Arrange — only Client A is connected. Client B is offline (never connects).
        var (deviceA, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var deviceB = Guid.NewGuid(); // Never connects — simulates offline device.

        await using var connectionA = CreateHubConnection(deviceA, tokenA);
        await connectionA.StartAsync();

        // Act — send a message to the offline device.
        var payload = Convert.ToBase64String(new byte[] { 0xCA, 0xFE });
        await connectionA.InvokeAsync("SendMessage", deviceB, payload);

        // Assert — the message should be stored in the database queue.
        // Small delay to let the server-side async work complete.
        await Task.Delay(200);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var queued = await db.QueuedMessages
            .Where(m => m.RecipientId == deviceB && m.SenderId == deviceA)
            .ToListAsync();

        queued.Should().HaveCount(1, "the message should be queued for the offline recipient");
        queued[0].EncryptedBody.Should().BeEquivalentTo(new byte[] { 0xCA, 0xFE },
            "the server should decode base64 and store raw bytes for queued messages");

        await connectionA.StopAsync();
    }

    [Fact]
    public async Task CallSignal_relays_to_online_target()
    {
        // Arrange — two devices for a WebRTC call signaling scenario.
        var (deviceA, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (deviceB, tokenB) = await RegisterDeviceAndGetTokenAsync();

        var signalTcs = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA, tokenA);
        await using var connectionB = CreateHubConnection(deviceB, tokenB);

        // Client B listens for call signals (offer, answer, ICE candidates).
        connectionB.On<JsonElement>("CallSignal", signal =>
        {
            signalTcs.TrySetResult(signal);
        });

        await connectionA.StartAsync();
        await connectionB.StartAsync();

        // Act — Client A sends a call offer to Client B.
        await connectionA.InvokeAsync("CallSignal", deviceB, "offer", "{\"sdp\":\"test\"}");

        // Assert — Client B should receive the relayed call signal.
        var received = await signalTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));

        received.GetProperty("senderId").GetString().Should().Be(deviceA.ToString());
        received.GetProperty("signalType").GetString().Should().Be("offer");
        received.GetProperty("payload").GetString().Should().Be("{\"sdp\":\"test\"}");

        await connectionA.StopAsync();
        await connectionB.StopAsync();
    }

    [Fact]
    public async Task CallSignal_offer_to_offline_target_tells_the_caller_immediately()
    {
        // Beta feedback: calling an offline contact rang until the 45 s client
        // timeout. The hub now answers the OFFER with an "unavailable" signal
        // that echoes the envelope so the caller can match it to its callId.
        var (deviceA, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (deviceB, _) = await RegisterDeviceAndGetTokenAsync(); // registered, never connects

        var signals = new List<JsonElement>();
        var firstSignal = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA, tokenA);
        connectionA.On<JsonElement>("CallSignal", signal =>
        {
            lock (signals) signals.Add(signal);
            firstSignal.TrySetResult(signal);
        });
        await connectionA.StartAsync();

        const string envelope = "{\"v\":1,\"callId\":\"3f2b7c1e-9a4d-4c55-8f10-6d2e1a7b9c01\",\"payload\":\"v=0\"}";
        await connectionA.InvokeAsync("CallSignal", deviceB, "offer", envelope);

        var received = await firstSignal.Task.WaitAsync(TimeSpan.FromSeconds(10));
        received.GetProperty("senderId").GetString().Should().Be(deviceB.ToString());
        received.GetProperty("signalType").GetString().Should().Be("unavailable");
        received.GetProperty("payload").GetString().Should().Be(envelope);

        // Follow-up signals of a call are still dropped silently — only the
        // offer is answered, otherwise every trickled ICE candidate would echo.
        await connectionA.InvokeAsync("CallSignal", deviceB, "ice-candidate", envelope);
        await connectionA.InvokeAsync("CallSignal", deviceB, "hangup", envelope);
        await Task.Delay(500);
        lock (signals) signals.Should().HaveCount(1);

        await connectionA.StopAsync();
    }

    [Fact]
    public async Task TypingIndicator_delivers_to_selected_recipient()
    {
        // Arrange — two devices in a conversation. Client A starts typing,
        // Client B should see the typing indicator.
        var (deviceA, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (deviceB, tokenB) = await RegisterDeviceAndGetTokenAsync();
        var conversationId = deviceB.ToString();

        var typingTcs = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA, tokenA);
        await using var connectionB = CreateHubConnection(deviceB, tokenB);

        connectionB.On<JsonElement>("TypingIndicator", indicator =>
        {
            typingTcs.TrySetResult(indicator);
        });

        await connectionA.StartAsync();
        await connectionB.StartAsync();

        // Act — Client A sends a typing indicator.
        await connectionA.InvokeAsync("TypingIndicator", conversationId);

        // Assert — Client B should receive the typing indicator.
        var received = await typingTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));

        received.GetProperty("senderId").GetString().Should().Be(deviceA.ToString());
        received.GetProperty("conversationId").GetString().Should().Be(conversationId);

        await connectionA.StopAsync();
        await connectionB.StopAsync();
    }

    [Fact]
    public async Task Disconnect_removes_connection_and_queues_subsequent_messages()
    {
        // Arrange — Client B connects then disconnects. Messages sent after
        // disconnect should be queued, not delivered directly.
        var (deviceA, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (deviceB, tokenB) = await RegisterDeviceAndGetTokenAsync();

        await using var connectionA = CreateHubConnection(deviceA, tokenA);
        await using var connectionB = CreateHubConnection(deviceB, tokenB);

        await connectionA.StartAsync();
        await connectionB.StartAsync();

        // Disconnect Client B — the hub should remove it from OnlineDevices.
        await connectionB.StopAsync();

        // Brief delay to ensure the disconnect handler runs on the server.
        await Task.Delay(200);

        // Act — Client A sends a message to the now-offline Client B.
        var payload = Convert.ToBase64String(new byte[] { 0xAA, 0xBB });
        await connectionA.InvokeAsync("SendMessage", deviceB, payload);

        // Assert — the message should be in the database queue since B is offline.
        await Task.Delay(200);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var queued = await db.QueuedMessages
            .Where(m => m.RecipientId == deviceB && m.SenderId == deviceA)
            .CountAsync();

        queued.Should().Be(1, "message to a disconnected device should be queued, not lost");

        await connectionA.StopAsync();
    }
    [Fact]
    public async Task Reliable_online_message_replays_after_reconnect_until_recipient_acknowledges()
    {
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, recipientToken) = await RegisterDeviceAndGetTokenAsync();
        var id = Guid.NewGuid();
        await using var sending = CreateHubConnection(sender, senderToken);
        await using var receiving = CreateHubConnection(recipient, recipientToken);
        var first = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        receiving.On<JsonElement>("ReceiveMessage", m => first.TrySetResult(m));
        await sending.StartAsync();
        await receiving.StartAsync();
        await sending.InvokeAsync("SendReliableMessage", recipient, id, "AQI=");
        (await first.Task.WaitAsync(TimeSpan.FromSeconds(10))).GetProperty("messageId").GetGuid().Should().Be(id);
        var retry = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var retryHandler = receiving.On<JsonElement>("ReceiveMessage", m => retry.TrySetResult(m));
        await receiving.InvokeAsync("RequestPendingMessages");
        (await retry.Task.WaitAsync(TimeSpan.FromSeconds(10))).GetProperty("messageId").GetGuid().Should().Be(id);
        await receiving.StopAsync();
        await sending.InvokeAsync("AcknowledgeMessage", sender, id);
        await using var reconnected = CreateHubConnection(recipient, recipientToken);
        var replay = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        reconnected.On<JsonElement>("ReceiveMessage", m => replay.TrySetResult(m));
        await reconnected.StartAsync();
        (await replay.Task.WaitAsync(TimeSpan.FromSeconds(10))).GetProperty("messageId").GetGuid().Should().Be(id);
        await reconnected.InvokeAsync("AcknowledgeMessage", sender, id);
        await sending.InvokeAsync("SendReliableMessage", recipient, id, "AQI=");
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var stored = await db.QueuedMessages.AsNoTracking().SingleAsync(m => m.MessageId == id);
        stored.AcknowledgedAt.Should().NotBeNull();
        stored.EncryptedBody.Should().BeEmpty();
    }

    [Fact]
    public async Task Group_send_checks_membership_and_offline_delivery_retains_group_id()
    {
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, recipientToken) = await RegisterDeviceAndGetTokenAsync();
        var (outsider, outsiderToken) = await RegisterDeviceAndGetTokenAsync();
        var group = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.AddRange(new GroupMember { GroupId = group, DeviceId = sender },
                new GroupMember { GroupId = group, DeviceId = recipient });
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(sender, senderToken);
        await using var intruder = CreateHubConnection(outsider, outsiderToken);
        await sending.StartAsync();
        await intruder.StartAsync();
        var badSender = () => intruder.InvokeAsync("SendReliableGroupMessage", group, Guid.NewGuid(),
            new Dictionary<Guid, string> { [recipient] = "AQI=" });
        await badSender.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>();
        var badRecipient = () => sending.InvokeAsync("SendReliableGroupMessage", group, Guid.NewGuid(),
            new Dictionary<Guid, string> { [outsider] = "AQI=" });
        await badRecipient.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>();
        var id = Guid.NewGuid();
        await sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=" });
        await using var receiving = CreateHubConnection(recipient, recipientToken);
        var delivered = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        receiving.On<JsonElement>("ReceiveMessage", m => delivered.TrySetResult(m));
        await receiving.StartAsync();
        var message = await delivered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        message.GetProperty("groupId").GetGuid().Should().Be(group);
        message.GetProperty("messageId").GetGuid().Should().Be(id);
    }    [Fact]
    public async Task Group_removal_excludes_future_fanout_without_deleting_earlier_messages()
    {
        // Arrange — A, B, C in a group. A sends to B and C while all are members.
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, tokenB) = await RegisterDeviceAndGetTokenAsync();
        var (c, tokenC) = await RegisterDeviceAndGetTokenAsync();
        var group = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = a, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = a },
                new GroupMember { GroupId = group, DeviceId = b },
                new GroupMember { GroupId = group, DeviceId = c });
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(a, tokenA);
        await sending.StartAsync();
        var earlierId = Guid.NewGuid();
        await sending.InvokeAsync("SendReliableGroupMessage", group, earlierId,
            new Dictionary<Guid, string> { [b] = "AQI=", [c] = "AQI=" });

        // Act — C is removed from the group (direct DB manipulation, equivalent
        // to what GroupEndpoints' member-removal does).
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var membership = await db.GroupMembers.SingleAsync(m => m.GroupId == group && m.DeviceId == c);
            db.GroupMembers.Remove(membership);
            await db.SaveChangesAsync();
        }

        // C's own further attempts to send into the group must now be rejected.
        await using var removed = CreateHubConnection(c, tokenC);
        await removed.StartAsync();
        var rejectedSend = () => removed.InvokeAsync("SendReliableGroupMessage", group, Guid.NewGuid(),
            new Dictionary<Guid, string> { [b] = "AQI=" });
        await rejectedSend.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>();

        // A new fan-out excludes C entirely.
        var laterId = Guid.NewGuid();
        var laterRejected = () => sending.InvokeAsync("SendReliableGroupMessage", group, laterId,
            new Dictionary<Guid, string> { [b] = "AQI=", [c] = "AQI=" });
        await laterRejected.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>(
            "the sender-and-recipients membership check must reject a payload naming a removed member");

        var laterOkId = Guid.NewGuid();
        await sending.InvokeAsync("SendReliableGroupMessage", group, laterOkId,
            new Dictionary<Guid, string> { [b] = "AQI=" });

        // Assert — the earlier message addressed to C is untouched by the removal.
        using var verify = Factory.Services.CreateScope();
        var verifyDb = verify.ServiceProvider.GetRequiredService<AppDbContext>();
        var earlierForC = await verifyDb.QueuedMessages.AsNoTracking()
            .SingleOrDefaultAsync(m => m.RecipientId == c && m.MessageId == earlierId);
        earlierForC.Should().NotBeNull("removal must not retroactively delete already-queued messages");
        var laterForC = await verifyDb.QueuedMessages.AsNoTracking()
            .Where(m => m.RecipientId == c && m.MessageId == laterOkId).CountAsync();
        laterForC.Should().Be(0, "a removed member must not appear in a new fan-out");

        await removed.StopAsync();
        await sending.StopAsync();
    }

    [Fact]
    public async Task Foreign_ack_is_ignored_and_replayed_overwrite_with_different_payload_is_rejected()
    {
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        var (attacker, attackerToken) = await RegisterDeviceAndGetTokenAsync();
        var id = Guid.NewGuid();
        await using var sending = CreateHubConnection(sender, senderToken);
        await sending.StartAsync();
        await sending.InvokeAsync("SendReliableMessage", recipient, id, "AQI=");

        // An attacker who is not the true recipient (per JWT) cannot ack it away.
        await using var attackerConn = CreateHubConnection(attacker, attackerToken);
        await attackerConn.StartAsync();
        await attackerConn.InvokeAsync("AcknowledgeMessage", sender, id);

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var stored = await db.QueuedMessages.AsNoTracking().SingleAsync(m =>
                m.RecipientId == recipient && m.SenderId == sender && m.MessageId == id);
            stored.AcknowledgedAt.Should().BeNull("only the true JWT-identified recipient may acknowledge");
        }

        // Retrying the same messageId with a different ciphertext must not overwrite the original.
        await sending.InvokeAsync("SendReliableMessage", recipient, id, "AwQ=");
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var stored = await db.QueuedMessages.AsNoTracking().SingleAsync(m =>
                m.RecipientId == recipient && m.SenderId == sender && m.MessageId == id);
            stored.EncryptedBody.Should().BeEquivalentTo(Convert.FromBase64String("AQI="),
                "the original ciphertext must not be replaced by a same-id resend with a different body");
        }

        await attackerConn.StopAsync();
        await sending.StopAsync();
    }

    [Fact]
    public async Task Group_fanout_exceeding_hub_invocation_limit_fails_visibly_with_no_partial_writes()
    {
        // Program.cs caps SignalR.MaximumReceiveMessageSize at 1 MiB. A group
        // fan-out whose combined per-recipient payloads exceed that must fail
        // the whole invocation rather than silently succeeding for some
        // recipients and dropping others.
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var members = new List<Guid> { sender };
        var payloads = new Dictionary<Guid, string>();
        // ~300 KiB per recipient x 5 recipients pushes the whole invocation past 1 MiB.
        var chunk = Convert.ToBase64String(new byte[300 * 1024]);
        for (var i = 0; i < 5; i++)
        {
            var (member, _) = await RegisterDeviceAndGetTokenAsync();
            members.Add(member);
            payloads[member] = chunk;
        }
        var group = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.AddRange(members.Select(m => new GroupMember { GroupId = group, DeviceId = m }));
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(sender, senderToken);
        await sending.StartAsync();
        var id = Guid.NewGuid();

        // Act — the oversized invocation must throw, never report a silent "sent".
        var send = () => sending.InvokeAsync("SendReliableGroupMessage", group, id, payloads);
        await send.Should().ThrowAsync<Exception>("an over-limit SignalR invocation must surface as an error");

        // Assert — no partial writes landed for any recipient.
        using var verify = Factory.Services.CreateScope();
        var verifyDb = verify.ServiceProvider.GetRequiredService<AppDbContext>();
        var written = await verifyDb.QueuedMessages.AsNoTracking().Where(m => m.MessageId == id).CountAsync();
        written.Should().Be(0, "a rejected invocation must not partially persist any recipient's message");

        await sending.StopAsync();
    }

    [Fact]
    public async Task Business_group_fanout_without_auditor_payload_is_rejected_and_nothing_is_queued()
    {
        // KB2 — server-side enforcement: a business group's fan-out MUST name
        // the org's auditor device, or the message would never be archived.
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        // Real registered device: GroupMember.DeviceId is an FK to Devices.
        var (auditor, auditorToken) = await RegisterDeviceAndGetTokenAsync();
        var group = Guid.NewGuid();
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = sender, Role = "admin" },
                new GroupMember { GroupId = group, DeviceId = recipient, Role = "member" },
                new GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(sender, senderToken);
        // W2-F: the auditor must be connected (alive) so this test exercises
        // KB2 (audit_recipient_missing), not the new auditor_unavailable gate.
        await using var auditing = CreateHubConnection(auditor, auditorToken);
        await sending.StartAsync();
        await auditing.StartAsync();
        var id = Guid.NewGuid();

        // Act — a payload that omits the auditor must be rejected outright.
        var send = () => sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=" });
        (await send.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>()).Which.Message
            .Should().Contain("audit_recipient_missing");

        using var verify = Factory.Services.CreateScope();
        var verifyDb = verify.ServiceProvider.GetRequiredService<AppDbContext>();
        var written = await verifyDb.QueuedMessages.AsNoTracking().Where(m => m.MessageId == id).CountAsync();
        written.Should().Be(0, "a rejected KB2 fan-out must not partially persist any recipient's message");

        await sending.StopAsync();
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Business_group_fanout_with_auditor_payload_delivers_to_everyone_exactly_once()
    {
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, recipientToken) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, auditorToken) = await RegisterDeviceAndGetTokenAsync();
        var group = Guid.NewGuid();
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = sender, Role = "admin" },
                new GroupMember { GroupId = group, DeviceId = recipient, Role = "member" },
                new GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(sender, senderToken);
        await using var receiving = CreateHubConnection(recipient, recipientToken);
        await using var auditing = CreateHubConnection(auditor, auditorToken);
        var recipientMsg = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var auditorMsg = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        receiving.On<JsonElement>("ReceiveMessage", m => recipientMsg.TrySetResult(m));
        auditing.On<JsonElement>("ReceiveMessage", m => auditorMsg.TrySetResult(m));
        await sending.StartAsync();
        await receiving.StartAsync();
        await auditing.StartAsync();
        var id = Guid.NewGuid();

        await sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=", [auditor] = "AQI=" });

        (await recipientMsg.Task.WaitAsync(TimeSpan.FromSeconds(10))).GetProperty("messageId").GetGuid().Should().Be(id);
        (await auditorMsg.Task.WaitAsync(TimeSpan.FromSeconds(10))).GetProperty("messageId").GetGuid().Should().Be(id);

        using var verify = Factory.Services.CreateScope();
        var verifyDb = verify.ServiceProvider.GetRequiredService<AppDbContext>();
        var forAuditor = await verifyDb.QueuedMessages.AsNoTracking()
            .Where(m => m.RecipientId == auditor && m.MessageId == id).CountAsync();
        forAuditor.Should().Be(1, "the auditor must be delivered to exactly once, like any other recipient");

        await sending.StopAsync();
        await receiving.StopAsync();
        await auditing.StopAsync();
    }

    /// <summary>
    /// Creates a business group (auditor role, real Organization row) and,
    /// optionally, seeds an un-acked QueuedMessage for the auditor so the
    /// backlog half of AuditorLivenessService can be exercised. Returns the
    /// group id — the caller decides whether/when to connect the auditor.
    /// </summary>
    private async Task<Guid> CreateBusinessGroupWithAuditorAsync(Guid sender, Guid recipient, Guid auditor,
        Guid organizationId, DateTimeOffset? staleBacklogCreatedAt = null)
    {
        var group = Guid.NewGuid();
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.Groups.Add(new Group { GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId });
        db.GroupMembers.AddRange(
            new GroupMember { GroupId = group, DeviceId = sender, Role = "admin" },
            new GroupMember { GroupId = group, DeviceId = recipient, Role = "member" },
            new GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
        if (staleBacklogCreatedAt is { } createdAt)
            db.QueuedMessages.Add(new QueuedMessage
            {
                // A GROUP message: only those count as archive backlog (a 1:1
                // message to the auditor can come from anyone and is never archived).
                MessageId = Guid.NewGuid(), GroupId = group, RecipientId = auditor, SenderId = sender,
                EncryptedBody = [0x01], CreatedAt = createdAt, ExpiresAt = createdAt.AddDays(30)
            });
        await db.SaveChangesAsync();
        return group;
    }

    [Fact]
    public async Task Business_send_is_accepted_and_queued_while_the_auditor_is_offline()
    {
        // The auditor is an ordinary store-and-forward recipient: while it is
        // offline its copy waits in the queue and is archived on reconnect, so
        // a short outage must NOT stop business traffic (owner decision
        // 2026-09-18, replacing the earlier "must be connected" rule).
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, _) = await RegisterDeviceAndGetTokenAsync(); // never connects
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        var group = await CreateBusinessGroupWithAuditorAsync(sender, recipient, auditor, organizationId);
        await using var sending = CreateHubConnection(sender, senderToken);
        await sending.StartAsync();
        var id = Guid.NewGuid();

        await sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=", [auditor] = "AQI=" });

        using var verify = Factory.Services.CreateScope();
        var written = await verify.ServiceProvider.GetRequiredService<AppDbContext>()
            .QueuedMessages.AsNoTracking().Where(m => m.MessageId == id).CountAsync();
        written.Should().Be(2, "the auditor's copy waits in the queue until the archiver returns");

        await sending.StopAsync();
    }

    [Fact]
    public async Task Business_send_is_accepted_when_the_auditor_is_connected()
    {
        // W2-F (b): the straightforward alive case.
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, auditorToken) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        var group = await CreateBusinessGroupWithAuditorAsync(sender, recipient, auditor, organizationId);
        await using var sending = CreateHubConnection(sender, senderToken);
        await using var auditing = CreateHubConnection(auditor, auditorToken);
        await sending.StartAsync();
        await auditing.StartAsync();
        var id = Guid.NewGuid();

        await sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=", [auditor] = "AQI=" });

        using var verify = Factory.Services.CreateScope();
        var written = await verify.ServiceProvider.GetRequiredService<AppDbContext>()
            .QueuedMessages.AsNoTracking().Where(m => m.MessageId == id).CountAsync();
        written.Should().Be(2, "recipient and auditor both get a QueuedMessage row");

        await sending.StopAsync();
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Business_send_is_rejected_when_the_auditor_backlog_is_stale()
    {
        // The one fail-closed condition: the auditor has not consumed its queue
        // for longer than the threshold. Queued copies expire after 30 days, so
        // an archiver that never comes back would silently lose records —
        // business traffic stops long before that, whether or not it is online.
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, auditorToken) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        var group = await CreateBusinessGroupWithAuditorAsync(sender, recipient, auditor, organizationId,
            staleBacklogCreatedAt: DateTimeOffset.UtcNow.AddDays(-2)); // default threshold is 24 h
        await using var sending = CreateHubConnection(sender, senderToken);
        await using var auditing = CreateHubConnection(auditor, auditorToken);
        await sending.StartAsync();
        await auditing.StartAsync();
        var id = Guid.NewGuid();

        var send = () => sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=", [auditor] = "AQI=" });
        (await send.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>()).Which.Message
            .Should().Contain("auditor_unavailable");

        await sending.StopAsync();
        await auditing.StopAsync();
    }

    [Fact]
    public async Task An_old_direct_message_to_the_auditor_does_not_block_business_traffic()
    {
        // Security review finding: ANY device may address a 1:1 message to the
        // auditor's device id, and the archiver never processes (so never acks)
        // those. If they counted as archive backlog, one outsider message would
        // shut down a whole organization's business messaging.
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, auditorToken) = await RegisterDeviceAndGetTokenAsync();
        var (outsider, _) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        var group = await CreateBusinessGroupWithAuditorAsync(sender, recipient, auditor, organizationId);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var old = DateTimeOffset.UtcNow.AddDays(-2);
            db.QueuedMessages.Add(new QueuedMessage
            {
                MessageId = Guid.NewGuid(), GroupId = null, RecipientId = auditor, SenderId = outsider,
                EncryptedBody = [0x01], CreatedAt = old, ExpiresAt = old.AddDays(30)
            });
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(sender, senderToken);
        await using var auditing = CreateHubConnection(auditor, auditorToken);
        await sending.StartAsync();
        await auditing.StartAsync();
        // Full hub round trip: OnConnectedAsync has registered the auditor by now.
        await auditing.InvokeAsync("RequestPendingMessages");

        await sending.InvokeAsync("SendReliableGroupMessage", group, Guid.NewGuid(),
            new Dictionary<Guid, string> { [recipient] = "AQI=", [auditor] = "AQI=" });

        await sending.StopAsync();
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Emergency_group_send_succeeds_even_with_a_dead_auditor()
    {
        // W2-F (e): the owner's deliberate exception — the emergency group
        // stays fail-OPEN so it works exactly when infrastructure is failing.
        var (sender, senderToken) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, _) = await RegisterDeviceAndGetTokenAsync(); // never connects
        var organizationId = await CreateBusinessOrganizationAsync(auditor);
        var group = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            // A two-day-old un-acked group message = the auditor counts as dead.
            var stale = DateTimeOffset.UtcNow.AddDays(-2);
            db.QueuedMessages.Add(new QueuedMessage
            {
                MessageId = Guid.NewGuid(), GroupId = Guid.NewGuid(), RecipientId = auditor, SenderId = sender,
                EncryptedBody = [0x01], CreatedAt = stale, ExpiresAt = stale.AddDays(30)
            });
            db.Groups.Add(new Group
            {
                GroupId = group, CreatedBy = sender, CreatedAt = DateTimeOffset.UtcNow,
                OrganizationId = organizationId, IsEmergencyChannel = true
            });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = group, DeviceId = sender, Role = "admin" },
                new GroupMember { GroupId = group, DeviceId = recipient, Role = "member" },
                new GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
            await db.SaveChangesAsync();
        }
        await using var sending = CreateHubConnection(sender, senderToken);
        await sending.StartAsync();
        var id = Guid.NewGuid();

        await sending.InvokeAsync("SendReliableGroupMessage", group, id,
            new Dictionary<Guid, string> { [recipient] = "AQI=", [auditor] = "AQI=" });

        using var verify = Factory.Services.CreateScope();
        var written = await verify.ServiceProvider.GetRequiredService<AppDbContext>()
            .QueuedMessages.AsNoTracking().Where(m => m.MessageId == id).CountAsync();
        written.Should().Be(2, "the emergency exception queues normally even with a dead auditor");

        await sending.StopAsync();
    }

    [Fact]
    public async Task Attachment_sized_encoded_payload_is_queued_and_oversize_is_rejected()
    {
        var (sender, token) = await RegisterDeviceAndGetTokenAsync();
        var (recipient, _) = await RegisterDeviceAndGetTokenAsync();
        await using var connection = CreateHubConnection(sender, token);
        await connection.StartAsync();
        var id = Guid.NewGuid();
        var payload = Convert.ToBase64String(new byte[512 * 1024]);
        await connection.InvokeAsync("SendReliableMessage", recipient, id, payload);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var stored = await db.QueuedMessages.SingleAsync(m => m.MessageId == id);
        stored.EncryptedBody.Should().HaveCount(512 * 1024);
        var oversized = Convert.ToBase64String(new byte[576 * 1024 + 1]);
        var send = () => connection.InvokeAsync("SendReliableMessage", recipient, Guid.NewGuid(), oversized);
        await send.Should().ThrowAsync<Microsoft.AspNetCore.SignalR.HubException>();
    }}
