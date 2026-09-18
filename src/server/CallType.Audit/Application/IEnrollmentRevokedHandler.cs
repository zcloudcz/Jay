// ---------------------------------------------------------------------------
// IEnrollmentRevokedHandler.cs — seam for E02 to react to enrollment revocation
// ---------------------------------------------------------------------------
// DELETE /orgs/{id}/enrollments/{deviceId} lives in E01 (Organization
// context), but removing a device from all of that organization's Delivery
// groups is E02's job (plan §5, row E02: "revokace enrollmentu -> odebrani ze
// skupin"). Rather than E01 reaching into Delivery's GroupMember table
// itself, it calls this handler after the enrollment is revoked. E01
// registers a no-op default so business mode works before E02 lands; E02
// registers its real implementation in Program.cs, overriding the no-op.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Application;

public interface IEnrollmentRevokedHandler
{
    Task OnEnrollmentRevokedAsync(Guid organizationId, Guid deviceId, CancellationToken ct);
}

/// <summary>Default registration until E02 wires up the real handler.</summary>
public class NoOpEnrollmentRevokedHandler : IEnrollmentRevokedHandler
{
    public Task OnEnrollmentRevokedAsync(Guid organizationId, Guid deviceId, CancellationToken ct) => Task.CompletedTask;
}
