// ---------------------------------------------------------------------------
// MessageQueueServiceTests.cs — Integration tests for the message queue
// ---------------------------------------------------------------------------
// Tests run against a real PostgreSQL instance via Testcontainers to verify
// the store-and-forward behavior, FIFO ordering, expiration filtering, and
// atomic dequeue semantics. No mocks — we test the actual SQL + transactions
// that will run in production.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class MessageQueueServiceTests : IntegrationTestBase
{
    /// <summary>
    /// Helper to create a MessageQueueService with a fresh DbContext scope.
    /// Each test gets its own scope so EF change tracking doesn't leak
    /// between operations within the same test.
    /// </summary>
    private MessageQueueService CreateService(IServiceScope scope)
    {
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return new MessageQueueService(db);
    }

    [Fact]
    public async Task Reliable_resend_and_recipient_scoped_ack_preserve_idempotency()
    {
        using var scope = Factory.Services.CreateScope();
        var service = CreateService(scope);
        var recipient = Guid.NewGuid();
        var sender = Guid.NewGuid();
        var id = Guid.NewGuid();
        var group = Guid.NewGuid();
        await service.EnqueueReliableAsync(recipient, sender, id, [1, 2], group);
        await service.EnqueueReliableAsync(recipient, sender, id, [1, 2], group);
        var pending = await service.DequeueAsync(recipient);
        pending.Should().ContainSingle();
        pending[0].MessageId.Should().Be(id);
        pending[0].GroupId.Should().Be(group);
        await service.AcknowledgeAsync(Guid.NewGuid(), sender, id);
        (await service.DequeueAsync(recipient)).Should().ContainSingle();
        await service.AcknowledgeAsync(recipient, sender, id);
        (await service.DequeueAsync(recipient)).Should().BeEmpty();
        var retry = await service.EnqueueReliableAsync(recipient, sender, id, [1, 2], group);
        retry.AcknowledgedAt.Should().NotBeNull();
        (await service.DequeueAsync(recipient)).Should().BeEmpty();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.QueuedMessages.AsNoTracking().SingleAsync(m => m.MessageId == id)).EncryptedBody.Should().BeEmpty();
    }
    [Fact]
    public async Task Enqueue_stores_encrypted_message()
    {
        // Arrange
        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();
        var body = new byte[] { 0xCA, 0xFE, 0xBA, 0xBE };

        using var scope = Factory.Services.CreateScope();
        var service = CreateService(scope);

        // Act
        await service.EnqueueAsync(recipientId, senderId, body);

        // Assert — verify the message landed in the database with correct fields.
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var stored = await db.QueuedMessages
            .SingleAsync(m => m.RecipientId == recipientId);

        stored.SenderId.Should().Be(senderId);
        stored.EncryptedBody.Should().BeEquivalentTo(body);
        stored.ExpiresAt.Should().BeAfter(DateTimeOffset.UtcNow.AddDays(29),
            "TTL should be approximately 30 days from now");
    }

    [Fact]
    public async Task Dequeue_returns_messages_without_deleting_before_ack()
    {
        // Arrange — enqueue two messages for the same recipient.
        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();

        using (var enqueueScope = Factory.Services.CreateScope())
        {
            var service = CreateService(enqueueScope);
            await service.EnqueueAsync(recipientId, senderId, [0x01]);
            await service.EnqueueAsync(recipientId, senderId, [0x02]);
        }

        // Act — dequeue should return both messages.
        List<DequeuedMessage> result;
        using (var dequeueScope = Factory.Services.CreateScope())
        {
            var service = CreateService(dequeueScope);
            result = await service.DequeueAsync(recipientId);
        }

        // Assert — got 2 messages back.
        result.Should().HaveCount(2);

        // Fetching must not remove messages before recipient persistence.
        using var verifyScope = Factory.Services.CreateScope();
        var db = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var remaining = await db.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .CountAsync();

        remaining.Should().Be(2, "delivery must retain messages until recipient acknowledgement");
    }

    [Fact]
    public async Task Dequeue_returns_empty_when_no_messages()
    {
        // Arrange — a recipient with no queued messages at all.
        var recipientId = Guid.NewGuid();

        using var scope = Factory.Services.CreateScope();
        var service = CreateService(scope);

        // Act
        var result = await service.DequeueAsync(recipientId);

        // Assert
        result.Should().BeEmpty("no messages were enqueued for this recipient");
    }

    [Fact]
    public async Task Dequeue_skips_expired_messages()
    {
        // Arrange — insert an expired message directly into the database,
        // bypassing EnqueueAsync which always sets a future ExpiresAt.
        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();

        using (var insertScope = Factory.Services.CreateScope())
        {
            var db = insertScope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.QueuedMessages.Add(new QueuedMessage
            {
                RecipientId = recipientId,
                SenderId = senderId,
                EncryptedBody = [0xFF],
                CreatedAt = DateTimeOffset.UtcNow.AddDays(-31),
                // Expired yesterday — should not be returned by DequeueAsync.
                ExpiresAt = DateTimeOffset.UtcNow.AddDays(-1)
            });
            await db.SaveChangesAsync();
        }

        // Act
        List<DequeuedMessage> result;
        using (var dequeueScope = Factory.Services.CreateScope())
        {
            var service = CreateService(dequeueScope);
            result = await service.DequeueAsync(recipientId);
        }

        // Assert — expired message should be excluded from the result.
        result.Should().BeEmpty("expired messages must not be delivered");

        // The expired row should also be cleaned up (deleted as a side effect).
        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var remaining = await verifyDb.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .CountAsync();

        remaining.Should().Be(0, "expired messages should be cleaned up during dequeue");
    }

    [Fact]
    public async Task Dequeue_returns_messages_in_order()
    {
        // Arrange — enqueue messages with deliberate ordering to verify FIFO.
        // We space them apart so CreatedAt values are distinct and the order
        // is unambiguous even with clock granularity on fast machines.
        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();

        using (var insertScope = Factory.Services.CreateScope())
        {
            var db = insertScope.ServiceProvider.GetRequiredService<AppDbContext>();
            var now = DateTimeOffset.UtcNow;

            // Insert in reverse order (3, 2, 1) to ensure the service sorts
            // by CreatedAt and doesn't just return insertion order.
            for (var i = 3; i >= 1; i--)
            {
                db.QueuedMessages.Add(new QueuedMessage
                {
                    RecipientId = recipientId,
                    SenderId = senderId,
                    EncryptedBody = [(byte)i],
                    CreatedAt = now.AddSeconds(i),
                    ExpiresAt = now.AddDays(30)
                });
            }

            await db.SaveChangesAsync();
        }

        // Act
        List<DequeuedMessage> result;
        using (var dequeueScope = Factory.Services.CreateScope())
        {
            var service = CreateService(dequeueScope);
            result = await service.DequeueAsync(recipientId);
        }

        // Assert — messages should come out in CreatedAt ascending order (FIFO).
        result.Should().HaveCount(3);
        result.Select(m => m.EncryptedBody[0]).Should().BeInAscendingOrder(
            "messages must be delivered in FIFO order based on CreatedAt");
    }
    [Fact]
    public async Task Concurrent_retries_store_only_one_message()
    {
        var recipient = Guid.NewGuid();
        var sender = Guid.NewGuid();
        var id = Guid.NewGuid();
        await Task.WhenAll(Enumerable.Range(0, 8).Select(async _ =>
        {
            using var scope = Factory.Services.CreateScope();
            await CreateService(scope).EnqueueReliableAsync(recipient, sender, id, [1]);
        }));
        using var verify = Factory.Services.CreateScope();
        (await CreateService(verify).DequeueAsync(recipient)).Should().ContainSingle();
    }    [Fact]
    public async Task Migration_preserves_existing_queued_messages_with_distinct_ids()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.ExecuteSqlRawAsync("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
        var migrator = db.GetService<IMigrator>();
        await migrator.MigrateAsync("20260604064437_AddDeviceSecretHash");
        var recipient = Guid.NewGuid();
        var sender = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        var expiry = now.AddDays(30);
        for (var i = 0; i < 2; i++)
            await db.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO "QueuedMessages" ("RecipientId", "SenderId", "EncryptedBody", "CreatedAt", "ExpiresAt")
                VALUES ({recipient}, {sender}, {new byte[] { 1 }}, {now}, {expiry})
                """);
        await migrator.MigrateAsync();
        var messages = await CreateService(scope).DequeueAsync(recipient);
        messages.Should().HaveCount(2);
        messages.Select(m => m.MessageId).Should().OnlyHaveUniqueItems().And.NotContain(Guid.Empty);
    }}
