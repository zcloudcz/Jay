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
// "FOR UPDATE" locks the previous row so two concurrent writers for the same
// organization serialize on computing the next Sequence/PrevHash instead of
// both reading the same tail and racing on the unique (OrganizationId,
// Sequence) index.
// ponytail: FOR UPDATE + Postgres row lock is a per-organization lock, not a
// distributed one — fine at pilot scale; if a hot org becomes a bottleneck,
// consider batching consecutive events into one row.
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
        var prev = await db.AdminAuditEvents
            .FromSqlInterpolated($"""
                SELECT * FROM "AdminAuditEvents"
                WHERE "OrganizationId" = {organizationId}
                ORDER BY "Sequence" DESC
                LIMIT 1
                FOR UPDATE
                """)
            .AsNoTracking()
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
