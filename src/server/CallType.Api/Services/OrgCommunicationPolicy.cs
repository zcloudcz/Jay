// ---------------------------------------------------------------------------
// OrgCommunicationPolicy.cs — "must these two devices talk in a business
// conversation instead?" (P1, plan §8a item 5)
// ---------------------------------------------------------------------------
// Owner decision: the DEFAULT stays that two members enrolled in the same
// organization may still talk anonymously outside of it (1:1, anonymous
// group, anonymous call) — a business group is opt-in per conversation. An
// organization can additionally switch on Organization.RequireBusinessConversations
// ("audit all communication between our members"); once on, the server
// refuses those anonymous paths between two ACTIVELY enrolled devices of that
// organization. The organization's auditor device is never enrolled (it sits
// behind Organization.AuditorDeviceId, not OrgEnrollment), so a lookup miss
// for it is naturally "allowed" — nothing special-cases it here.
//
// Business mode can be entirely disabled (BusinessModeOptions.Enabled ==
// false) — in that case this must return "allowed" WITHOUT touching
// AuditDbContext, same rule every other business-adjacent code path follows.
//
// The 1:1 send path is hot, and the enrollment data lives in the OTHER
// database (KB3: no cross-DB join), so a short in-memory cache per device
// pair avoids two extra queries on every message. Cache invalidation: none —
// same tradeoff AuditorLivenessService.IsAliveAsync already makes, just
// documented again here. The cache duration is configurable
// (Business:PolicyCacheSeconds) specifically so tests that flip the policy
// mid-test can set it to 0.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using CallType.Api.Configuration;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Services;

public class OrgCommunicationPolicy(
    AuditDbContext auditDb,
    BusinessModeOptions businessMode,
    IMemoryCache cache,
    IOptions<BusinessOptions> options)
{
    /// <summary>
    /// True when deviceA and deviceB may talk outside a business conversation
    /// (the common case). False when both are actively enrolled in an
    /// organization whose RequireBusinessConversations policy is on, and the
    /// caller should reject with "business_conversation_required".
    /// </summary>
    public async Task<bool> IsAllowedAsync(Guid deviceA, Guid deviceB, CancellationToken ct)
    {
        if (!businessMode.Enabled) return true;
        if (deviceA == deviceB) return true;

        // Order-independent cache key — the pair means the same thing either way.
        var (low, high) = deviceA.CompareTo(deviceB) <= 0 ? (deviceA, deviceB) : (deviceB, deviceA);
        var cacheKey = $"org-comm-policy:{low}:{high}";
        if (cache.TryGetValue(cacheKey, out bool cached))
            return cached;

        var allowed = await ComputeAllowedAsync(deviceA, deviceB, ct);
        var duration = TimeSpan.FromSeconds(Math.Max(0, options.Value.PolicyCacheSeconds));
        if (duration > TimeSpan.Zero)
            cache.Set(cacheKey, allowed, duration);
        return allowed;
    }

    private async Task<bool> ComputeAllowedAsync(Guid deviceA, Guid deviceB, CancellationToken ct)
    {
        // Both devices' active enrollments, intersected in memory — a
        // cross-database join isn't possible (KB3), and this is at most a
        // handful of rows per device.
        var enrollments = await auditDb.OrgEnrollments.AsNoTracking()
            .Where(e => (e.DeviceId == deviceA || e.DeviceId == deviceB) && e.RevokedAt == null)
            .Select(e => new { e.OrganizationId, e.DeviceId })
            .ToListAsync(ct);

        var sharedOrgIds = enrollments.Where(e => e.DeviceId == deviceA).Select(e => e.OrganizationId)
            .Intersect(enrollments.Where(e => e.DeviceId == deviceB).Select(e => e.OrganizationId))
            .ToList();
        if (sharedOrgIds.Count == 0) return true;

        var anyRequiresBusinessConversations = await auditDb.Organizations.AsNoTracking()
            .Where(o => sharedOrgIds.Contains(o.OrganizationId) && o.RequireBusinessConversations)
            .AnyAsync(ct);
        return !anyRequiresBusinessConversations;
    }
}
