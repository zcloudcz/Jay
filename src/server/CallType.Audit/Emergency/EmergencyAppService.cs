// ---------------------------------------------------------------------------
// EmergencyAppService.cs — E07: emergency kits, offline enrollment, drills
// ---------------------------------------------------------------------------
// Audit-DB-only orchestration (KB3 — CallType.Audit never references
// AppDbContext). Everything that needs Delivery data (adding the enrolled
// device to the organization's emergency group, pushing the drill hub event)
// happens in CallType.Api.Endpoints.EmergencyEndpoints after this service's
// calls return, mirroring how E01's OrganizationAppService / E02's
// BusinessGroupService are split across the same seam.
//
// Every mutating call wraps its domain change + AdminAuditWriter.AppendAsync
// + SaveChangesAsync in one transaction (KB6), same discipline as
// OrganizationAppService.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;
using CallType.Audit.OrgManagement;

namespace CallType.Audit.Emergency;

public class EmergencyAppService(AuditDbContext db)
{
    public const int MaxKitCodes = 50;

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/kits
    // -----------------------------------------------------------------
    public async Task<IssuedKit> IssueKitAsync(Guid organizationId, Guid actorAccountId, string label, int count, DateTimeOffset now, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        if (count is < 1 or > MaxKitCodes)
            throw new DomainRuleViolation("invalid_count", $"count must be between 1 and {MaxKitCodes}.");
        if (string.IsNullOrWhiteSpace(label) || label.Length > 200 || label.Contains('') || label.Contains('\0'))
            throw new DomainRuleViolation("invalid_label", "Invalid label.");

        // Checked BEFORE anything is written: the emergency group is a business
        // group and cannot exist without its auditor (KB1). This database is
        // append-only, so a kit written ahead of a failing precondition would
        // stay forever — with codes nobody was ever shown — and appear in the
        // proof export.
        var hasAuditor = await db.Organizations
            .AnyAsync(o => o.OrganizationId == organizationId && o.AuditorDeviceId != null, ct);
        if (!hasAuditor)
            throw new DomainRuleViolation("auditor_not_configured", "Organization has no auditor device configured yet.");

        var kitId = Guid.NewGuid();
        var recoveryCode = EmergencyCodes.Generate();
        var kit = new EmergencyKit(kitId, organizationId, EmergencyCodes.Hash(recoveryCode), label.Trim(), now);
        db.EmergencyKits.Add(kit);

        var codes = new List<string>(count);
        for (var i = 0; i < count; i++)
        {
            var code = EmergencyCodes.Generate();
            codes.Add(code);
            db.EmergencyEnrollmentCodes.Add(new EmergencyEnrollmentCode(Guid.NewGuid(), kitId, organizationId, EmergencyCodes.Hash(code)));
        }

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "emergency_kit_issued",
            new { kitId, label = kit.Label, count }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        // Plaintext codes are returned here ONCE and never persisted — the
        // caller (endpoint) must not log them.
        return new IssuedKit(kitId, kit.Label, now, recoveryCode, codes);
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/emergency/kits
    // -----------------------------------------------------------------
    public async Task<List<KitSummary>> ListKitsAsync(Guid organizationId, Guid actorAccountId, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        var kits = await db.EmergencyKits.AsNoTracking()
            .Where(k => k.OrganizationId == organizationId)
            .OrderByDescending(k => k.IssuedAt)
            .ToListAsync(ct);

        var result = new List<KitSummary>(kits.Count);
        foreach (var kit in kits)
        {
            var total = await db.EmergencyEnrollmentCodes.CountAsync(c => c.KitId == kit.KitId, ct);
            var used = await db.EmergencyEnrollmentCodes.CountAsync(c => c.KitId == kit.KitId && c.UsedAt != null, ct);
            result.Add(new KitSummary(kit.KitId, kit.Label, kit.IssuedAt, kit.RevokedAt, total, total - used));
        }
        return result;
    }

    // -----------------------------------------------------------------
    // DELETE /orgs/{id}/emergency/kits/{kitId}
    // -----------------------------------------------------------------
    public async Task RevokeKitAsync(Guid organizationId, Guid actorAccountId, Guid kitId, DateTimeOffset now, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        var kit = await db.EmergencyKits.SingleOrDefaultAsync(k => k.KitId == kitId && k.OrganizationId == organizationId, ct)
            ?? throw new DomainRuleViolation("kit_not_found", "No such emergency kit.");
        if (kit.RevokedAt is not null) return; // idempotent

        kit.RevokedAt = now;

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "emergency_kit_revoked", new { kitId }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------
    // POST /orgs/emergency/enroll
    // -----------------------------------------------------------------
    public async Task<EmergencyEnrollResult> EnrollAsync(string code, Guid deviceId, Guid? accountId, DateTimeOffset now, CancellationToken ct)
    {
        var hash = EmergencyCodes.Hash(code);
        var entry = await db.EmergencyEnrollmentCodes.SingleOrDefaultAsync(c => c.CodeHash == hash, ct)
            ?? throw new DomainRuleViolation("emergency_code_invalid", "Unknown emergency code.");

        var kit = await db.EmergencyKits.SingleAsync(k => k.KitId == entry.KitId, ct);
        if (kit.RevokedAt is not null)
            throw new DomainRuleViolation("kit_revoked", "This emergency kit has been revoked.");
        if (entry.UsedAt is not null)
            throw new DomainRuleViolation("emergency_code_used", "This emergency code was already used.");

        var existing = await db.OrgEnrollments.SingleOrDefaultAsync(
            e => e.OrganizationId == kit.OrganizationId && e.DeviceId == deviceId, ct);

        await using var tx = await db.Database.BeginTransactionAsync(ct);

        entry.UsedAt = now;
        entry.UsedByDeviceId = deviceId;

        var alreadyEnrolled = existing is { RevokedAt: null };
        if (existing is null)
        {
            // OrgEnrollment.Enroll wants an OrgInvite to redeem (E01's domain
            // rule for "an enrollment can't exist without a validly consumed
            // invite") — the emergency code IS that invite here, so a
            // throwaway, never-persisted OrgInvite satisfies the invariant
            // without adding a second code table with overlapping meaning.
            var throwaway = new OrgInvite(Guid.NewGuid(), kit.OrganizationId, code, Guid.Empty, now.AddMinutes(-1), now.AddMinutes(1));
            db.OrgEnrollments.Add(OrgEnrollment.Enroll(throwaway, deviceId, accountId ?? Guid.Empty, now));
        }
        else if (existing.RevokedAt is not null)
        {
            existing.RevokedAt = null; // re-enrolling via a fresh emergency code un-revokes the device
        }

        await AdminAuditWriter.AppendAsync(db, kit.OrganizationId, accountId ?? Guid.Empty, "emergency_device_enrolled",
            new { deviceId, kitId = kit.KitId }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return new EmergencyEnrollResult(kit.OrganizationId, alreadyEnrolled);
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/drills
    // -----------------------------------------------------------------
    public async Task<long> StartDrillAsync(Guid organizationId, Guid actorAccountId, DateTimeOffset now, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        var drill = new EmergencyDrill(organizationId, now);
        db.EmergencyDrills.Add(drill);

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await db.SaveChangesAsync(ct); // need the identity Id before we can log it
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "emergency_drill_started", new { drillId = drill.Id }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return drill.Id;
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/drills/{drillId}/confirm
    // -----------------------------------------------------------------
    public async Task ConfirmDrillAsync(Guid organizationId, long drillId, Guid deviceId, DateTimeOffset now, CancellationToken ct)
    {
        var drill = await db.EmergencyDrills.SingleOrDefaultAsync(d => d.Id == drillId && d.OrganizationId == organizationId, ct)
            ?? throw new DomainRuleViolation("drill_not_found", "No such drill.");
        if (drill.CompletedAt is not null) return; // drill already closed — ignore late confirmations

        var already = await db.EmergencyDrillConfirmations.AnyAsync(c => c.DrillId == drillId && c.DeviceId == deviceId, ct);
        if (already) return; // only the first confirmation per device counts

        db.EmergencyDrillConfirmations.Add(new EmergencyDrillConfirmation(drillId, deviceId, now));
        drill.ConfirmedMemberCount = await db.EmergencyDrillConfirmations.CountAsync(c => c.DrillId == drillId, ct) + 1;
        await db.SaveChangesAsync(ct);
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/drills/{drillId}/complete
    // -----------------------------------------------------------------
    public async Task CompleteDrillAsync(Guid organizationId, Guid actorAccountId, long drillId, DateTimeOffset now, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        var drill = await db.EmergencyDrills.SingleOrDefaultAsync(d => d.Id == drillId && d.OrganizationId == organizationId, ct)
            ?? throw new DomainRuleViolation("drill_not_found", "No such drill.");
        if (drill.CompletedAt is not null) return; // idempotent

        var confirmations = await db.EmergencyDrillConfirmations
            .Where(c => c.DrillId == drillId).Select(c => c.ConfirmedAt).ToListAsync(ct);

        drill.CompletedAt = now;
        drill.ConfirmedMemberCount = confirmations.Count;
        // Worst-case response time (MAX, not median) — a drill is only as good
        // as its slowest responder for an emergency-readiness proof.
        drill.ResponseTime = confirmations.Count == 0 ? null : confirmations.Max(c => c - drill.StartedAt);

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await AdminAuditWriter.AppendAsync(db, organizationId, actorAccountId, "emergency_drill_completed",
            new { drillId, confirmedMemberCount = drill.ConfirmedMemberCount, responseTimeSeconds = drill.ResponseTime?.TotalSeconds }, now, ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/emergency/drills
    // -----------------------------------------------------------------
    public async Task<List<DrillSummary>> ListDrillsAsync(Guid organizationId, Guid actorAccountId, CancellationToken ct)
    {
        await RequireAdminAsync(organizationId, actorAccountId, ct);

        return await db.EmergencyDrills.AsNoTracking()
            .Where(d => d.OrganizationId == organizationId)
            .OrderByDescending(d => d.StartedAt)
            .Select(d => new DrillSummary(d.Id, d.StartedAt, d.CompletedAt, d.ConfirmedMemberCount, d.ResponseTime))
            .ToListAsync(ct);
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/emergency/proof — data only; CallType.Api formats it
    // -----------------------------------------------------------------
    public async Task<EmergencyProofAuditData> GetProofAuditDataAsync(Guid organizationId, Guid actorAccountId, CancellationToken ct)
    {
        var org = await RequireAdminAsync(organizationId, actorAccountId, ct);

        var kitsIssued = await db.EmergencyKits.CountAsync(k => k.OrganizationId == organizationId, ct);
        var kitsRevoked = await db.EmergencyKits.CountAsync(k => k.OrganizationId == organizationId && k.RevokedAt != null, ct);
        var lastDrill = await db.EmergencyDrills.AsNoTracking()
            .Where(d => d.OrganizationId == organizationId && d.CompletedAt != null)
            .OrderByDescending(d => d.CompletedAt)
            .Select(d => new DrillSummary(d.Id, d.StartedAt, d.CompletedAt, d.ConfirmedMemberCount, d.ResponseTime))
            .FirstOrDefaultAsync(ct);

        var lastArchiveRecord = await db.AuditRecords.AsNoTracking()
            .Where(r => r.OrganizationId == organizationId)
            .OrderByDescending(r => r.Sequence)
            .FirstOrDefaultAsync(ct);

        return new EmergencyProofAuditData(
            organizationId, org.Name, org.AuditorDeviceId, kitsIssued, kitsRevoked, lastDrill,
            lastArchiveRecord?.Sequence ?? 0, lastArchiveRecord is null ? null : Convert.ToHexString(lastArchiveRecord.Hash));
    }

    // -----------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------
    private async Task<Domain.Organization> RequireAdminAsync(Guid organizationId, Guid actorAccountId, CancellationToken ct)
    {
        var org = await db.Organizations.Include(o => o.Members).SingleOrDefaultAsync(o => o.OrganizationId == organizationId, ct)
            ?? throw new DomainRuleViolation("org_not_found", "Organization not found.");
        var role = org.Members.FirstOrDefault(m => m.AccountId == actorAccountId && m.RemovedAt is null)?.Role;
        if (role is not (OrgRole.Owner or OrgRole.OrgAdmin))
            throw new DomainRuleViolation("forbidden", "Caller is not an org-admin of this organization.");
        return org;
    }
}

/// <summary>Audit-DB-only facts for the proof export; CallType.Api adds Delivery-side facts
/// (emergency group existence, enrolled member count) before hashing/serializing the document.</summary>
public record EmergencyProofAuditData(
    Guid OrganizationId, string OrganizationName, Guid? AuditorDeviceId,
    int KitsIssued, int KitsRevoked, DrillSummary? LastCompletedDrill,
    long ArchiveLastSequence, string? ArchiveLastHash);
