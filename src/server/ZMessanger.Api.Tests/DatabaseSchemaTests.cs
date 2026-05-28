// ---------------------------------------------------------------------------
// DatabaseSchemaTests.cs — Integration tests for the EF Core schema
// ---------------------------------------------------------------------------
// Verifies that the database schema is correctly applied and that basic
// CRUD operations work against a real PostgreSQL instance (via Testcontainers).
// These tests catch mapping errors, constraint violations, and index issues
// that in-memory providers would silently ignore.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests;

public class DatabaseSchemaTests : IntegrationTestBase
{
    [Fact]
    public async Task Schema_creation_succeeds_and_all_tables_exist()
    {
        // Arrange — schema was already applied in InitializeAsync.
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        // Act — query the PostgreSQL information_schema for our tables.
        var connection = db.Database.GetDbConnection();
        await connection.OpenAsync();

        await using var cmd = connection.CreateCommand();
        cmd.CommandText = """
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'public'
            ORDER BY table_name;
            """;

        var tables = new List<string>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            tables.Add(reader.GetString(0));

        // Assert — all expected tables must be present.
        var expectedTables = new[]
        {
            "AccountDevices", "Accounts", "Backups", "Devices",
            "GroupMembers", "Groups", "OneTimePreKeys", "QueuedMessages"
        };

        foreach (var table in expectedTables)
        {
            tables.Should().Contain(
                t => string.Equals(t, table, StringComparison.OrdinalIgnoreCase),
                $"Table '{table}' should exist in the database");
        }
    }

    [Fact]
    public async Task Can_insert_and_read_device_with_one_time_pre_keys()
    {
        // Arrange
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "alice#1",
            IdentityKey = [0x01, 0x02, 0x03],
            SignedPreKey = [0x04, 0x05, 0x06],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow,
            OneTimePreKeys =
            [
                new OneTimePreKey { KeyId = 1, PublicKey = [0x0A] },
                new OneTimePreKey { KeyId = 2, PublicKey = [0x0B] }
            ]
        };

        // Act
        db.Devices.Add(device);
        await db.SaveChangesAsync();

        // Read back from a fresh context to ensure data was persisted.
        await using var verifyDb = new AppDbContext(
            scope.ServiceProvider.GetRequiredService<DbContextOptions<AppDbContext>>());

        var loaded = await verifyDb.Devices
            .Include(d => d.OneTimePreKeys)
            .SingleAsync(d => d.DeviceId == device.DeviceId);

        // Assert
        loaded.UserHandle.Should().Be("alice#1");
        loaded.IdentityKey.Should().BeEquivalentTo(new byte[] { 0x01, 0x02, 0x03 });
        loaded.OneTimePreKeys.Should().HaveCount(2);
    }

    [Fact]
    public async Task UserHandle_unique_constraint_prevents_duplicates()
    {
        // Arrange
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device1 = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "dupe#1",
            IdentityKey = [0x01],
            SignedPreKey = [0x02],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow
        };

        var device2 = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "dupe#1", // same handle — should fail
            IdentityKey = [0x03],
            SignedPreKey = [0x04],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow
        };

        db.Devices.Add(device1);
        await db.SaveChangesAsync();

        // Act & Assert — the unique index on UserHandle must reject this.
        db.Devices.Add(device2);
        var act = () => db.SaveChangesAsync();
        await act.Should().ThrowAsync<DbUpdateException>();
    }

    [Fact]
    public async Task Can_create_account_with_device_link_and_backup()
    {
        // Arrange
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "bob#42",
            IdentityKey = [0x10],
            SignedPreKey = [0x20],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow
        };

        var account = new Account
        {
            AccountId = Guid.NewGuid(),
            Email = "bob@example.com",
            AuthKeyHash = [0xFF, 0xFE],
            CreatedAt = DateTime.UtcNow,
            AccountDevices = [new AccountDevice { Device = device }],
            Backups =
            [
                new Backup
                {
                    BlobPath = "backups/test/1.enc",
                    SizeBytes = 1024,
                    CreatedAt = DateTime.UtcNow
                }
            ]
        };

        // Act
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        // Verify
        await using var verifyDb = new AppDbContext(
            scope.ServiceProvider.GetRequiredService<DbContextOptions<AppDbContext>>());

        var loaded = await verifyDb.Accounts
            .Include(a => a.AccountDevices)
            .Include(a => a.Backups)
            .SingleAsync(a => a.AccountId == account.AccountId);

        // Assert
        loaded.Email.Should().Be("bob@example.com");
        loaded.AccountDevices.Should().HaveCount(1);
        loaded.Backups.Should().HaveCount(1);
        loaded.Backups[0].BlobPath.Should().Be("backups/test/1.enc");
    }

    [Fact]
    public async Task Can_insert_and_query_queued_messages()
    {
        // Arrange
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();
        var now = DateTime.UtcNow;

        var messages = Enumerable.Range(1, 5).Select(i => new QueuedMessage
        {
            RecipientId = recipientId,
            SenderId = senderId,
            EncryptedBody = [(byte)i],
            CreatedAt = now.AddSeconds(i),
            ExpiresAt = now.AddDays(7)
        }).ToList();

        // Act
        db.QueuedMessages.AddRange(messages);
        await db.SaveChangesAsync();

        // Query using the covering index path: filter by RecipientId, order by CreatedAt.
        var fetched = await db.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .OrderBy(m => m.CreatedAt)
            .ToListAsync();

        // Assert
        fetched.Should().HaveCount(5);
        fetched.Select(m => m.EncryptedBody[0]).Should().BeInAscendingOrder();
    }

    [Fact]
    public async Task Can_create_group_with_members()
    {
        // Arrange
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device1 = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "grp#a",
            IdentityKey = [0x01],
            SignedPreKey = [0x02],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow
        };

        var device2 = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "grp#b",
            IdentityKey = [0x03],
            SignedPreKey = [0x04],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow
        };

        db.Devices.AddRange(device1, device2);
        await db.SaveChangesAsync();

        var group = new Group
        {
            GroupId = Guid.NewGuid(),
            NameEncrypted = [0xAA, 0xBB],
            CreatedBy = device1.DeviceId,
            CreatedAt = DateTime.UtcNow,
            Members =
            [
                new GroupMember
                {
                    DeviceId = device1.DeviceId,
                    Role = "admin",
                    JoinedAt = DateTime.UtcNow
                },
                new GroupMember
                {
                    DeviceId = device2.DeviceId,
                    // Role defaults to "member"
                    JoinedAt = DateTime.UtcNow
                }
            ]
        };

        // Act
        db.Groups.Add(group);
        await db.SaveChangesAsync();

        // Verify
        await using var verifyDb = new AppDbContext(
            scope.ServiceProvider.GetRequiredService<DbContextOptions<AppDbContext>>());

        var loaded = await verifyDb.Groups
            .Include(g => g.Members)
            .SingleAsync(g => g.GroupId == group.GroupId);

        // Assert
        loaded.Members.Should().HaveCount(2);
        loaded.Members.Should().ContainSingle(m => m.Role == "admin");
        loaded.Members.Should().ContainSingle(m => m.Role == "member");
    }

    [Fact]
    public async Task Health_endpoint_still_works_with_db_configured()
    {
        // Sanity check: the /health endpoint should remain functional
        // even after adding the DbContext to the DI container.
        var response = await Client.GetAsync("/health");
        response.StatusCode.Should().Be(System.Net.HttpStatusCode.OK);
    }

    [Fact]
    public async Task OneTimePreKey_unique_index_prevents_duplicate_key_ids_per_device()
    {
        // Arrange
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = "idx#1",
            IdentityKey = [0x01],
            SignedPreKey = [0x02],
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow
        };

        db.Devices.Add(device);
        await db.SaveChangesAsync();

        // Add first key
        db.OneTimePreKeys.Add(new OneTimePreKey
        {
            DeviceId = device.DeviceId,
            KeyId = 42,
            PublicKey = [0x0A]
        });
        await db.SaveChangesAsync();

        // Act & Assert — same (DeviceId, KeyId) should violate unique index.
        db.OneTimePreKeys.Add(new OneTimePreKey
        {
            DeviceId = device.DeviceId,
            KeyId = 42, // duplicate
            PublicKey = [0x0B]
        });
        var act = () => db.SaveChangesAsync();
        await act.Should().ThrowAsync<DbUpdateException>();
    }
}
