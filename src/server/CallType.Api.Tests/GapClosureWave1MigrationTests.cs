// ---------------------------------------------------------------------------
// GapClosureWave1MigrationTests.cs — X0's single EF migration (gap-contracts 2.1)
// ---------------------------------------------------------------------------
// IntegrationTestBase builds the schema with EnsureCreated, which never runs a
// migration file. Production applies migrations at startup, so this class
// drops the schema, migrates to the migration BEFORE GapClosureWave1, seeds a
// device exactly as an existing beta row looks, and then applies the new
// migration — the path every existing database takes. Real PostgreSQL
// (Testcontainers), never a mocked DB.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests;

public class GapClosureWave1MigrationTests : IntegrationTestBase
{
    private const string PreviousMigration = "20260918151915_AccountMfa";

    [Fact]
    public async Task Migration_applies_on_an_existing_database_and_backfills_existing_devices()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.ExecuteSqlRawAsync("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
        var migrator = db.GetService<IMigrator>();
        await migrator.MigrateAsync(PreviousMigration);

        // A device row as it exists on beta today (columns of the previous schema only).
        var deviceId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        await db.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO "Devices" ("DeviceId", "UserHandle", "IdentityKey", "SignedPreKey", "DeviceSecretHash",
                                   "IsBot", "CreatedAt", "LastSeenAt", "PushToken", "PushPlatform")
            VALUES ({deviceId}, 'CT-MIGR-TEST', {new byte[] { 1 }}, {new byte[] { 2 }}, {new byte[32]},
                    false, {now}, {now}, 'fcm-token', 'fcm')
            """);

        await migrator.MigrateAsync();

        (await db.Database.GetAppliedMigrationsAsync()).Should().Contain(m => m.EndsWith("_GapClosureWave1"));
        (await db.Database.GetPendingMigrationsAsync()).Should().BeEmpty();

        var device = await db.Devices.AsNoTracking().SingleAsync(d => d.DeviceId == deviceId);
        // Every pre-S2 client registered its single SPK with keyId 1.
        device.SignedPreKeyId.Should().Be(1);
        device.SignedPreKeyUpdatedAt.Should().BeNull();
        device.VoipPushToken.Should().BeNull();
        device.VoipPushEnvironment.Should().BeNull();
        device.PushKey.Should().BeNull();
        device.PushTokenUpdatedAt.Should().BeNull();
        device.PushToken.Should().Be("fcm-token", "the migration must not touch existing push registrations");

        // The new table is usable through the model (enum stored as text).
        db.E2eAttachments.Add(new E2eAttachment
        {
            BlobId = Guid.NewGuid(), UploaderDeviceId = deviceId, SizeBytes = 10, ChunkSizeBytes = 10,
            ChunkCount = 1, CreatedAt = now, ExpiresAt = now.AddHours(24)
        });
        await db.SaveChangesAsync();
        var status = await db.Database.SqlQueryRaw<string>("""SELECT "Status" AS "Value" FROM "E2eAttachments" """).SingleAsync();
        status.Should().Be("Uploading");
    }

    [Fact]
    public async Task Push_key_of_the_wrong_length_is_rejected_by_the_database()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.ExecuteSqlRawAsync("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
        await db.Database.MigrateAsync();

        var now = DateTimeOffset.UtcNow;
        Device NewDevice(string handle, byte[]? pushKey) => new()
        {
            DeviceId = Guid.NewGuid(), UserHandle = handle, IdentityKey = [1], SignedPreKey = [2],
            DeviceSecretHash = new byte[32], CreatedAt = now, LastSeenAt = now, PushKey = pushKey
        };

        db.Devices.Add(NewDevice("CT-KEYS-OK32", new byte[32]));
        await db.SaveChangesAsync();

        db.Devices.Add(NewDevice("CT-KEYS-BAD1", new byte[31]));
        var act = () => db.SaveChangesAsync();
        (await act.Should().ThrowAsync<DbUpdateException>())
            .WithInnerException<PostgresException>()
            .Which.ConstraintName.Should().Be("CK_Devices_PushKey_Length");
    }
}
