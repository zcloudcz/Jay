// ---------------------------------------------------------------------------
// AdminAuditWriter.cs — appends one chained AdminAuditEvent (KB6)
// ---------------------------------------------------------------------------
// Every mutating Organization-context action writes one of these in the same
// transaction as the mutation itself, chained via HashChain exactly like
// AuditRecord (E03) but as its own, separate per-organization chain. Callers
// are expected to wrap the domain mutation + this call + SaveChangesAsync in
// one transaction (see OrganizationAppService) so a rollback never leaves a
// membership change without its audit event or vice versa.
//
// A per-organization advisory lock (pg_advisory_xact_lock) serializes
// concurrent writers on computing the next Sequence/PrevHash, so they never
// both read the same tail and race on the unique (OrganizationId, Sequence)
// index. Row locks (FOR UPDATE) are deliberately not used: the audit app role
// has no UPDATE privilege (KB3) and PostgreSQL requires it for row locks.
// ponytail: advisory lock is per organization inside one PostgreSQL — fine at
// pilot scale; if a hot org becomes a bottleneck, batch consecutive events.
// ---------------------------------------------------------------------------

using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using CallType.Audit.Application;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Audit.OrgManagement;

public static class AdminAuditWriter
{
    public static async Task AppendAsync(
        AuditDbContext db,
        Guid organizationId,
        Guid actorAccountId,
        string eventType,
        object details,
        DateTimeOffset now,
        CancellationToken ct)
    {
        // Serialize appends per organization with a transaction-scoped advisory
        // lock. SELECT ... FOR UPDATE is NOT an option here: the audit app role
        // holds only INSERT/SELECT (KB3) and PostgreSQL requires UPDATE
        // privilege for row locks. Advisory locks need no table privilege and
        // also cover the very first event of an organization (no row to lock).
        // The unique index on (OrganizationId, Sequence) remains the safety net.
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"SELECT pg_advisory_xact_lock(hashtext({"admin-audit:" + organizationId}))", ct);
        var prev = await db.AdminAuditEvents
            .AsNoTracking()
            .Where(e => e.OrganizationId == organizationId)
            .OrderByDescending(e => e.Sequence)
            .FirstOrDefaultAsync(ct);

        var sequence = (prev?.Sequence ?? 0) + 1;
        var prevHash = prev?.Hash ?? HashChain.Genesis;
        var detailsJson = JsonSerializer.Serialize(details);

        // Fixed field order — must never change, it's part of what makes the
        // chain reproducible offline (plan §KB4/audit-verify).
        var canonical = HashChain.Canonicalize([
            organizationId.ToString(),
            actorAccountId.ToString(),
            eventType,
            detailsJson,
            now.ToString("O"),
            sequence.ToString()
        ]);
        var hash = HashChain.ComputeHash(prevHash, canonical);

        db.AdminAuditEvents.Add(new AdminAuditEvent(
            organizationId, actorAccountId, eventType, detailsJson, now, sequence, prevHash, hash));
    }
}
