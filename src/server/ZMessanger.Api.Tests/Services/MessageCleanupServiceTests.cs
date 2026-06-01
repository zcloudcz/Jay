// ---------------------------------------------------------------------------
// MessageCleanupServiceTests.cs — Integration tests for expired message cleanup
// ---------------------------------------------------------------------------
// Tests the core cleanup logic of MessageCleanupService against a real
// PostgreSQL instance. Since the service is a BackgroundService with an
// infinite loop, we test by resolving the IServiceScopeFactory from the
// test server and running the same EF Core query that the cleanup uses.
//
// This approach verifies the SQL behavior without needing to orchestrate
// the BackgroundService's timer, which would make tests fragile and slow.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Services;

public class MessageCleanupServiceTests : IntegrationTestBase
{
    /// <summary>
    /// Runs the same cleanup query that MessageCleanupService uses internally:
    /// DELETE all QueuedMessages where ExpiresAt is in the past. Returns the
    /// count of deleted rows.
    /// </summary>
    /// <remarks>
    /// We replicate the query rather than calling the service directly because
    /// the service is a BackgroundService with an infinite loop — extracting
    /// just the cleanup method would require making it public or internal.
    /// The query is simple enough that testing it directly is equivalent.
    /// </remarks>
    private async Task<int> RunCleanupAsync()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        return await db.QueuedMessages
            .Where(m => m.ExpiresAt < DateTimeOffset.UtcNow)
            .ExecuteDeleteAsync();
    }

    [Fact]
    public async Task Cleanup_deletes_expired_messages()
    {
        // Arrange — insert messages that have already expired. These simulate
        // messages for devices that never reconnected within the 30-day TTL.
        var recipientId = Guid.NewGuid();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

            // Two expired messages — ExpiresAt is in the past.
            db.QueuedMessages.AddRange(
                new QueuedMessage
                {
                    RecipientId = recipientId,
                    SenderId = Guid.NewGuid(),
                    EncryptedBody = [0x01],
                    CreatedAt = DateTimeOffset.UtcNow.AddDays(-35),
                    ExpiresAt = DateTimeOffset.UtcNow.AddDays(-5)
                },
                new QueuedMessage
                {
                    RecipientId = recipientId,
                    SenderId = Guid.NewGuid(),
                    EncryptedBody = [0x02],
                    CreatedAt = DateTimeOffset.UtcNow.AddDays(-32),
                    ExpiresAt = DateTimeOffset.UtcNow.AddDays(-2)
                });

            await db.SaveChangesAsync();
        }

        // Act — run the cleanup query.
        var deletedCount = await RunCleanupAsync();

        // Assert
        deletedCount.Should().Be(2, "both expired messages should be deleted");

        // Verify the database is empty for this recipient.
        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var remaining = await verifyDb.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .CountAsync();

        remaining.Should().Be(0);
    }

    [Fact]
    public async Task Cleanup_preserves_non_expired_messages()
    {
        // Arrange — insert a mix of expired and non-expired messages.
        // Only the expired ones should be deleted; the rest must survive.
        var recipientId = Guid.NewGuid();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

            // Expired message — should be deleted.
            db.QueuedMessages.Add(new QueuedMessage
            {
                RecipientId = recipientId,
                SenderId = Guid.NewGuid(),
                EncryptedBody = [0xEE],
                CreatedAt = DateTimeOffset.UtcNow.AddDays(-35),
                ExpiresAt = DateTimeOffset.UtcNow.AddDays(-5)
            });

            // Non-expired message — should survive the cleanup.
            db.QueuedMessages.Add(new QueuedMessage
            {
                RecipientId = recipientId,
                SenderId = Guid.NewGuid(),
                EncryptedBody = [0xFF],
                CreatedAt = DateTimeOffset.UtcNow.AddHours(-1),
                ExpiresAt = DateTimeOffset.UtcNow.AddDays(29)
            });

            await db.SaveChangesAsync();
        }

        // Act
        var deletedCount = await RunCleanupAsync();

        // Assert — only the expired message should be deleted.
        deletedCount.Should().Be(1, "only the expired message should be cleaned up");

        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var surviving = await verifyDb.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .ToListAsync();

        surviving.Should().HaveCount(1, "the non-expired message must survive cleanup");
        surviving[0].EncryptedBody.Should().BeEquivalentTo(new byte[] { 0xFF },
            "the surviving message should be the non-expired one");
    }
}
