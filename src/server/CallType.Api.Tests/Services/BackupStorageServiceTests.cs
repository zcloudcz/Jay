// ---------------------------------------------------------------------------
// BackupStorageServiceTests.cs — Reservation quota + concurrency (K03 / D02)
// ---------------------------------------------------------------------------
// Exercises BackupStorageService directly against real PostgreSQL (via
// IntegrationTestBase) rather than through HTTP, so the concurrency test can
// fire two reservations at the exact same instant without HTTP pipeline jitter.
// ---------------------------------------------------------------------------

using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace CallType.Api.Tests.Services;

public class BackupStorageServiceTests : IntegrationTestBase
{
    /// <summary>Registers an account (no device link needed — the service doesn't check auth).</summary>
    private async Task<Guid> CreateAccountAsync()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var account = new Models.Account
        {
            AccountId = Guid.NewGuid(),
            Email = $"svc-test-{Guid.NewGuid():N}@example.com",
            AuthKeyHash = [0x01],
            CreatedAt = DateTimeOffset.UtcNow
        };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();
        return account.AccountId;
    }

    private BackupStorageService CreateService(out AppDbContext db)
    {
        var scope = Factory.Services.CreateScope();
        db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var limits = scope.ServiceProvider.GetRequiredService<IOptions<BackupLimitsOptions>>();
        return new BackupStorageService(db, limits);
    }

    [Fact]
    public async Task Reserve_then_confirm_marks_backup_completed()
    {
        var accountId = await CreateAccountAsync();
        var service = CreateService(out var db);

        var outcome = await service.ReserveAsync(accountId, 100, CancellationToken.None);
        outcome.Result.Should().Be(ReservationResult.Reserved);

        await service.ConfirmUploadAsync(outcome.Backup!.Id, 100, CancellationToken.None);

        var reloaded = await db.Backups.SingleAsync(b => b.Id == outcome.Backup.Id);
        reloaded.Status.Should().Be(BackupStatus.Completed);
        reloaded.ReservationExpiresAt.Should().BeNull();
    }

    [Fact]
    public async Task Reserve_for_unknown_account_returns_account_not_found()
    {
        var service = CreateService(out _);

        var outcome = await service.ReserveAsync(Guid.NewGuid(), 100, CancellationToken.None);

        outcome.Result.Should().Be(ReservationResult.AccountNotFound);
    }

    [Fact]
    public async Task Abort_reservation_deletes_the_row_and_frees_the_slot()
    {
        var accountId = await CreateAccountAsync();
        var service = CreateService(out var db);

        var outcome = await service.ReserveAsync(accountId, 100, CancellationToken.None);
        await service.AbortReservationAsync(outcome.Backup!.Id, CancellationToken.None);

        (await db.Backups.AnyAsync(b => b.Id == outcome.Backup.Id)).Should().BeFalse();

        // A fresh reservation should succeed — quota was actually released.
        var again = await service.ReserveAsync(accountId, 100, CancellationToken.None);
        again.Result.Should().Be(ReservationResult.Reserved);
    }

    [Fact]
    public async Task Concurrent_reservations_for_the_last_slot_yield_exactly_one_winner()
    {
        // Fill the account up to one slot below MaxPerAccount, then race two
        // reservations for that final slot. Reservation takes a DB-level
        // advisory lock, so the two requests serialize instead of both reading
        // "count = MaxPerAccount - 1" and both succeeding.
        var accountId = await CreateAccountAsync();
        var limits = Factory.Services.GetRequiredService<IOptions<BackupLimitsOptions>>().Value;

        for (var i = 0; i < limits.MaxPerAccount - 1; i++)
        {
            var service = CreateService(out _);
            var outcome = await service.ReserveAsync(accountId, 100, CancellationToken.None);
            outcome.Result.Should().Be(ReservationResult.Reserved);
        }

        // Each concurrent call needs its own DbContext (not thread-safe to share).
        var task1 = Task.Run(async () =>
        {
            var service = CreateService(out _);
            return await service.ReserveAsync(accountId, 100, CancellationToken.None);
        });
        var task2 = Task.Run(async () =>
        {
            var service = CreateService(out _);
            return await service.ReserveAsync(accountId, 100, CancellationToken.None);
        });

        var results = await Task.WhenAll(task1, task2);

        results.Count(r => r.Result == ReservationResult.Reserved).Should().Be(1);
        results.Count(r => r.Result == ReservationResult.QuotaExceeded).Should().Be(1);
    }

    [Fact]
    public async Task Reserve_beyond_global_byte_limit_returns_quota_exceeded()
    {
        var accountId = await CreateAccountAsync();
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var tightLimits = Options.Create(new BackupLimitsOptions { MaxTotalBytes = 500, MaxPerAccount = 10, MaxFileBytes = 1_000_000 });
        var service = new BackupStorageService(db, tightLimits);

        var first = await service.ReserveAsync(accountId, 400, CancellationToken.None);
        first.Result.Should().Be(ReservationResult.Reserved);

        var second = await service.ReserveAsync(accountId, 200, CancellationToken.None);
        second.Result.Should().Be(ReservationResult.QuotaExceeded);
    }
}
