// ---------------------------------------------------------------------------
// DeliveryDirectory.cs — IDeliveryDirectory implementation over AppDbContext
// ---------------------------------------------------------------------------
// The only place Organization-context code (CallType.Audit) reaches into
// Delivery data — through this seam, never a direct AppDbContext reference
// from CallType.Audit (KB3: separate databases, separate credentials).
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Audit.Application;

namespace CallType.Api.Services;

public class DeliveryDirectory(AppDbContext db) : IDeliveryDirectory
{
    public Task<bool> AccountExistsAsync(Guid accountId, CancellationToken ct) =>
        db.Accounts.AnyAsync(a => a.AccountId == accountId, ct);

    public Task<bool> DeviceExistsAsync(Guid deviceId, CancellationToken ct) =>
        db.Devices.AnyAsync(d => d.DeviceId == deviceId, ct);

    public Task<bool> IsDeviceLinkedToAccountAsync(Guid deviceId, Guid accountId, CancellationToken ct) =>
        db.AccountDevices.AnyAsync(ad => ad.DeviceId == deviceId && ad.AccountId == accountId, ct);

    public Task<bool> IsBotDeviceAsync(Guid deviceId, CancellationToken ct) =>
        db.Devices.AnyAsync(d => d.DeviceId == deviceId && d.IsBot, ct);
}
