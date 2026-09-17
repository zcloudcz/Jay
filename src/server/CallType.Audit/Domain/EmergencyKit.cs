// ---------------------------------------------------------------------------
// EmergencyKit.cs / EmergencyDrill.cs — offline enrollment + drills (E07)
// ---------------------------------------------------------------------------
// Owned by E07; the tables are defined here per plan §3 so E00's schema is
// complete and E07 doesn't need its own migration against this DbContext.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class EmergencyKit
{
    public Guid KitId { get; private set; }
    public Guid OrganizationId { get; private set; }

    /// <summary>Hash of the recovery code — the plaintext code is never stored server-side.</summary>
    public string RecoveryCodeHash { get; private set; } = string.Empty;

    public DateTimeOffset IssuedAt { get; private set; }
    public DateTimeOffset? RevokedAt { get; set; }

    private EmergencyKit()
    {
    } // EF Core

    public EmergencyKit(Guid kitId, Guid organizationId, string recoveryCodeHash, DateTimeOffset issuedAt)
    {
        KitId = kitId;
        OrganizationId = organizationId;
        RecoveryCodeHash = recoveryCodeHash;
        IssuedAt = issuedAt;
    }
}

public class EmergencyDrill
{
    public long Id { get; private set; }
    public Guid OrganizationId { get; private set; }
    public DateTimeOffset StartedAt { get; private set; }
    public DateTimeOffset? CompletedAt { get; set; }
    public int ConfirmedMemberCount { get; set; }
    public TimeSpan? ResponseTime { get; set; }

    private EmergencyDrill()
    {
    } // EF Core

    public EmergencyDrill(Guid organizationId, DateTimeOffset startedAt)
    {
        OrganizationId = organizationId;
        StartedAt = startedAt;
    }
}
