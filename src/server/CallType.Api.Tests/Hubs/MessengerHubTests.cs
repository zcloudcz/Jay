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
// ---------------------------------------------------------------------------

using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Hubs;

public class MessengerHubTests : IntegrationTestBase
{
    /// <summary>
    /// Builds a SignalR HubConnection that connects through the test server's
    /// in-process HTTP handler. This avoids opening real TCP sockets and keeps
    /// the test isolated. The deviceId query parameter identifies the connecting
    /// device to the hub.
    /// </summary>
    private HubConnection CreateHubConnection(Guid deviceId)
    {
        var server = Factory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?deviceId={deviceId}", options =>
            {
                // Route HTTP requests through the test server's in-process handler
                // instead of opening real network connections.
                options.HttpMessageHandlerFactory = _ => server.CreateHandler();
            })
            .Build();
    }

    [Fact]
    public async Task Client_connects_and_receives_queued_messages()
    {
        // Arrange — enqueue a message directly in the DB before the recipient connects.
        // This simulates the "device was offline, messages accumulated" scenario.
        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();
        var messageBody = new byte[] { 0xDE, 0xAD, 0xBE, 0xEF };

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

        await using var connection = CreateHubConnection(recipientId);
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

        // Verify the message was removed from the queue after delivery.
        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var remaining = await verifyDb.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .CountAsync();
        remaining.Should().Be(0, "queued messages should be deleted after delivery on connect");

        await connection.StopAsync();
    }

    [Fact]
    public async Task SendMessage_to_online_recipient_delivers_directly()
    {
        // Arrange — two devices connect to the hub. Client A sends a message
        // to Client B, who should receive it in real-time without DB queueing.
        var deviceA = Guid.NewGuid();
        var deviceB = Guid.NewGuid();

        var receivedTcs = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA);
        await using var connectionB = CreateHubConnection(deviceB);

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

        // The message should NOT be in the database — it was delivered directly.
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var queued = await db.QueuedMessages
            .Where(m => m.RecipientId == deviceB && m.SenderId == deviceA)
            .CountAsync();
        queued.Should().Be(0, "online delivery should skip the database queue");

        await connectionA.StopAsync();
        await connectionB.StopAsync();
    }

    [Fact]
    public async Task SendMessage_to_offline_recipient_queues_message()
    {
        // Arrange — only Client A is connected. Client B is offline (never connects).
        var deviceA = Guid.NewGuid();
        var deviceB = Guid.NewGuid(); // Never connects — simulates offline device.

        await using var connectionA = CreateHubConnection(deviceA);
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
        var deviceA = Guid.NewGuid();
        var deviceB = Guid.NewGuid();

        var signalTcs = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA);
        await using var connectionB = CreateHubConnection(deviceB);

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
    public async Task TypingIndicator_broadcasts_to_others()
    {
        // Arrange — two devices in a conversation. Client A starts typing,
        // Client B should see the typing indicator.
        var deviceA = Guid.NewGuid();
        var deviceB = Guid.NewGuid();
        var conversationId = "conv-" + Guid.NewGuid().ToString("N");

        var typingTcs = new TaskCompletionSource<JsonElement>();

        await using var connectionA = CreateHubConnection(deviceA);
        await using var connectionB = CreateHubConnection(deviceB);

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
        var deviceA = Guid.NewGuid();
        var deviceB = Guid.NewGuid();

        await using var connectionA = CreateHubConnection(deviceA);
        await using var connectionB = CreateHubConnection(deviceB);

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
}
