// ---------------------------------------------------------------------------
// EmergencyEnrollmentCode.cs — one one-time offline-enrollment code (E07)
// ---------------------------------------------------------------------------
// A kit issues N of these plus one recovery code (see EmergencyAppService).
// Only the hash is ever persisted (spec 2.3/2.9: "never log or persist
// plaintext codes") — the plaintext is returned to the admin exactly once,
// in the issue-kit response, and never retrievable again.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class EmergencyEnrollmentCode
{
    public Guid Id { get; private set; }
    public Guid KitId { get; private set; }
    public Guid OrganizationId { get; private set; }
    public string CodeHash { get; private set; } = string.Empty;
    public DateTimeOffset? UsedAt { get; set; }
    public Guid? UsedByDeviceId { get; set; }

    private EmergencyEnrollmentCode()
    {
    } // EF Core

    public EmergencyEnrollmentCode(Guid id, Guid kitId, Guid organizationId, string codeHash)
    {
        Id = id;
        KitId = kitId;
        OrganizationId = organizationId;
        CodeHash = codeHash;
    }
}

/// <summary>Per-device first-confirm record for an <see cref="EmergencyDrill"/> (E07).</summary>
public class EmergencyDrillConfirmation
{
    public long Id { get; private set; }
    public long DrillId { get; private set; }
    public Guid DeviceId { get; private set; }
    public DateTimeOffset ConfirmedAt { get; private set; }

    private EmergencyDrillConfirmation()
    {
    } // EF Core

    public EmergencyDrillConfirmation(long drillId, Guid deviceId, DateTimeOffset confirmedAt)
    {
        DrillId = drillId;
        DeviceId = deviceId;
        ConfirmedAt = confirmedAt;
    }
}
