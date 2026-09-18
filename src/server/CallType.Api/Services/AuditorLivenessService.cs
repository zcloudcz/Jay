// ---------------------------------------------------------------------------
// AuditorLivenessService.cs — "is this organization's auditor alive?" (W2-F)
// ---------------------------------------------------------------------------
// Owner decision 2026-09-18: business communication is FAIL-CLOSED on a dead
// auditor (the emergency group is the one deliberate exception, handled by
// callers checking Group.IsEmergencyChannel before calling this service).
//
// "Alive" = both:
//  1. connected right now, or disconnected less than AuditorDisconnectGraceSeconds
//     ago — MessengerHub's in-process connection map is the only presence
//     source (single API instance by design; after a restart nobody is
//     connected and there is no disconnect record, which correctly reads as
//     NOT alive until the archiver reconnects);
//  2. not stuck — the oldest un-acked QueuedMessage addressed to the auditor
//     is younger than AuditorMaxBacklogAgeSeconds.
//
// Short-lived per-organization cache so the hot send path (every group
// message) doesn't run the backlog query per message. 5 s default, matching
// the cache-must-not-mask-the-transition-longer-than-the-cache requirement.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Hubs;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Services;

public class AuditorLivenessService(
    AuditDbContext auditDb,
    AppDbContext db,
    IMemoryCache cache,
    IOptions<BusinessOptions> options,
    ILogger<AuditorLivenessService> logger)
{
    private static readonly TimeSpan CacheDuration = TimeSpan.FromSeconds(5);

    // Last alive/dead verdict per organization, kept only to log on the edges
    // (alive->dead / dead->alive), never as the source of truth for a check.
    private static readonly ConcurrentDictionary<Guid, bool> LastLoggedState = new();

    public async Task<bool> IsAliveAsync(Guid organizationId, CancellationToken ct)
    {
        var cacheKey = $"auditor-alive:{organizationId}";
        if (cache.TryGetValue(cacheKey, out bool cached))
            return cached;

        var alive = await ComputeAliveAsync(organizationId, ct);
        cache.Set(cacheKey, alive, CacheDuration);
        LogTransition(organizationId, alive);
        return alive;
    }

    private async Task<bool> ComputeAliveAsync(Guid organizationId, CancellationToken ct)
    {
        var auditorDeviceId = await auditDb.Organizations.AsNoTracking()
            .Where(o => o.OrganizationId == organizationId)
            .Select(o => o.AuditorDeviceId)
            .SingleOrDefaultAsync(ct);
        if (auditorDeviceId is not { } deviceId)
            return false;

        if (!IsConnectedOrWithinGrace(deviceId))
            return false;

        // Oldest un-acked message for the auditor — the existing (RecipientId,
        // CreatedAt) index covers this as an index-only scan.
        var oldestPending = await db.QueuedMessages.AsNoTracking()
            .Where(m => m.RecipientId == deviceId && m.AcknowledgedAt == null)
            .OrderBy(m => m.CreatedAt)
            .Select(m => (DateTimeOffset?)m.CreatedAt)
            .FirstOrDefaultAsync(ct);
        if (oldestPending is not { } oldest)
            return true; // no backlog at all

        var age = DateTimeOffset.UtcNow - oldest;
        return age.TotalSeconds < options.Value.AuditorMaxBacklogAgeSeconds;
    }

    private bool IsConnectedOrWithinGrace(Guid deviceId)
    {
        if (MessengerHub.IsOnline(deviceId))
            return true;
        var lastDisconnectedAt = MessengerHub.GetLastDisconnectedAt(deviceId);
        if (lastDisconnectedAt is null)
            return false; // never seen since process start
        return (DateTimeOffset.UtcNow - lastDisconnectedAt.Value).TotalSeconds
               < options.Value.AuditorDisconnectGraceSeconds;
    }

    private void LogTransition(Guid organizationId, bool alive)
    {
        // Log only device ids, never message content (KB3) — and only on the
        // edge, so a healthy archiver doesn't spam the log every 5 s.
        if (LastLoggedState.TryGetValue(organizationId, out var previous) && previous == alive)
            return;
        LastLoggedState[organizationId] = alive;
        logger.LogInformation(
            "Organization {OrganizationId} auditor liveness flipped to {State}",
            organizationId, alive ? "alive" : "dead");
    }
}
