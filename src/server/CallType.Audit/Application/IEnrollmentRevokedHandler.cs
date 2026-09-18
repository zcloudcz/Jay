// ---------------------------------------------------------------------------
// IEnrollmentRevokedHandler.cs — hook fired when a device's org enrollment is revoked
// ---------------------------------------------------------------------------
// E01 owns the endpoint that revokes an OrgEnrollment; E02 (Delivery side)
// needs to react by dropping the device from that organization's business
// groups so it stops receiving fan-out. Defined here (CallType.Audit) rather
// than in CallType.Api so either package can reference it without a circular
// dependency; CallType.Api provides the implementation (BusinessGroupService)
// and registers it in DI. See docs/superpowers/plans/2026-09-18-business-mode.md, E02 row.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Application;

public interface IEnrollmentRevokedHandler
{
    Task OnEnrollmentRevokedAsync(Guid organizationId, Guid deviceId, CancellationToken cancellationToken);
}
