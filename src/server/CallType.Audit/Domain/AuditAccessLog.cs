// ---------------------------------------------------------------------------
// AuditAccessLog.cs — append-only record of every archive read (KB5)
// ---------------------------------------------------------------------------
// No behavior beyond construction — this is a log entry, not an aggregate.
// Never updated or deleted once written (enforced at the DB role level, see
// infra/postgres/audit-roles.sql).
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class AuditAccessLog
{
    public long Id { get; private set; }
    public Guid RequestId { get; private set; }
    public Guid OrganizationId { get; private set; }
    public Guid AccessorAccountId { get; private set; }

    /// <summary>What was read (e.g. a record range or group id) — never message content.</summary>
    public string What { get; private set; } = string.Empty;

    public DateTimeOffset AccessedAt { get; private set; }

    private AuditAccessLog()
    {
    } // EF Core

    public AuditAccessLog(Guid requestId, Guid organizationId, Guid accessorAccountId, string what,
        DateTimeOffset accessedAt)
    {
        RequestId = requestId;
        OrganizationId = organizationId;
        AccessorAccountId = accessorAccountId;
        What = what;
        AccessedAt = accessedAt;
    }
}
