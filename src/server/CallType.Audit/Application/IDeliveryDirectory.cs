// ---------------------------------------------------------------------------
// IDeliveryDirectory.cs — read-only lookups into the Delivery database (E01)
// ---------------------------------------------------------------------------
// CallType.Audit must never reference AppDbContext (KB3 — separate DBs,
// separate credentials, no FK from Audit into Delivery). But Organization
// operations still need to know things Delivery owns: does an account exist,
// is a device already linked to it, is a candidate auditor device a real bot
// device. This interface is that seam — CallType.Api implements it against
// AppDbContext, CallType.Audit only ever sees the abstraction.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Application;

public interface IDeliveryDirectory
{
    Task<bool> AccountExistsAsync(Guid accountId, CancellationToken ct);

    Task<bool> DeviceExistsAsync(Guid deviceId, CancellationToken ct);

    /// <summary>True when the given device is linked to the given account (AccountDevice row).</summary>
    Task<bool> IsDeviceLinkedToAccountAsync(Guid deviceId, Guid accountId, CancellationToken ct);

    /// <summary>True only for a device that self-declared as a bot at registration (Device.IsBot).</summary>
    Task<bool> IsBotDeviceAsync(Guid deviceId, CancellationToken ct);
}
