// ---------------------------------------------------------------------------
// PrivacyEndpoints.cs — GDPR data-subject rights (N09)
// ---------------------------------------------------------------------------
// Three endpoints, all in one file because they share the same subject
// (what the server holds about a device/account) rather than one route group:
//   DELETE /devices/{deviceId}   — forget a device (queued messages, keys,
//                                  memberships, channel activity, push token).
//   DELETE /accounts/{accountId} — forget an account (proof-of-possession
//                                  required — irreversible), backups and all.
//   GET    /accounts/{accountId}/export — everything the server holds about
//                                  the account, in one JSON document.
//
// Business mode (Audit DB) interaction is deliberately asymmetric with the
// Delivery DB: the Audit DB is append-only history (KB3) and a device id /
// account id in it is a random identifier, not itself personal data, so
// enrollment and membership rows are NEVER deleted here — only checked as a
// precondition. See docs/security/data-subject-rights.md for the reasoning.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using Azure.Storage.Blobs;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Endpoints;

public static class PrivacyEndpoints
{
    private const string BackupContainerName = "backups";

    public static WebApplication MapPrivacyEndpoints(this WebApplication app)
    {
        // Irreversible actions get the stricter "auth" limiter, same reasoning
        // as login/link-device: slow down anyone probing with a stolen JWT.
        app.MapDelete("/devices/{deviceId:guid}", DeleteDevice).RequireAuthorization().RequireRateLimiting("auth");
        app.MapDelete("/accounts/{accountId:guid}", DeleteAccount).RequireAuthorization().RequireRateLimiting("auth");
        app.MapGet("/accounts/{accountId:guid}/export", ExportAccount).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------------
    // DELETE /devices/{deviceId}
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeleteDevice(
        Guid deviceId, ClaimsPrincipal user, AppDbContext db,
        BusinessModeOptions businessMode, HttpContext http, CancellationToken ct)
    {
        // Only the device itself can delete itself — there is no "account admin
        // deletes a device" flow (that already exists as group/channel member
        // removal, which does not touch the Device row).
        if (AccountEndpoints.CallerDeviceId(user) != deviceId) return Results.Forbid();

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == deviceId, ct);
        // Already gone (or never existed) — deleting is idempotent per the brief.
        if (device is null) return Results.NotFound();

        // A device that is the silent auditor of a business organization must
        // not disappear — every KB1 group in that organization would lose its
        // only archive path with no way to notice. Refuse and let the org
        // owner reassign the auditor first (no such flow exists yet either,
        // which is exactly why this device cannot be removed out from under it).
        if (businessMode.Enabled)
        {
            var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();
            var isAuditor = await auditDb.Organizations.AnyAsync(o => o.AuditorDeviceId == deviceId, ct);
            if (isAuditor)
                return Results.Conflict(new { error = "Device is the auditor of an organization.", code = "device_is_auditor" });

            // Enrollment rows in the Audit DB are append-only history (legal
            // obligation retention — KB3) and are intentionally NOT touched
            // here. A device id is a random identifier, not personal data on
            // its own, so leaving the enrollment row behind does not defeat
            // the deletion. Only the Delivery-side data below is removed.
        }

        await using var tx = await db.Database.BeginTransactionAsync(ct);

        // Channel.FollowerCount is denormalized (see the WARNING comment on
        // ChannelFollower in AppDbContext.OnModelCreating) — a plain cascade
        // delete of ChannelFollower rows would leave it too high. Decrement it
        // with one set-based UPDATE (not a per-row loop) BEFORE the cascade
        // removes the ChannelFollower rows it joins against.
        await db.Database.ExecuteSqlRawAsync(
            """
            UPDATE "Channels" c SET "FollowerCount" = c."FollowerCount" - 1
            FROM "ChannelFollowers" f
            WHERE f."ChannelId" = c."ChannelId" AND f."DeviceId" = @deviceId
            """,
            [new NpgsqlParameter("@deviceId", deviceId)], ct);

        // QueuedMessage has no FK to Device (RecipientId/SenderId are plain
        // columns — messages must outlive an unrelated device's deletion) so
        // it is not cascaded and must be cleared explicitly in both directions.
        await db.Database.ExecuteSqlRawAsync(
            """DELETE FROM "QueuedMessages" WHERE "RecipientId" = @deviceId OR "SenderId" = @deviceId""",
            [new NpgsqlParameter("@deviceId", deviceId)], ct);

        // Deleting the Device row cascades (DB-level ON DELETE CASCADE, see
        // AppDbContext): OneTimePreKeys, AccountDevices, GroupMembers,
        // ChannelFollowers, ChannelReactions, ChannelPollVotes, ChannelAdmins.
        // Groups the device CREATED (Group.CreatedBy) and channels OWNED
        // through its account are untouched — CreatedBy is informational-only
        // (not a FK) and channel ownership comes from OwnerAccountId, not the
        // device, so both survive the device's deletion by design.
        await db.Database.ExecuteSqlRawAsync(
            """DELETE FROM "Devices" WHERE "DeviceId" = @deviceId""",
            [new NpgsqlParameter("@deviceId", deviceId)], ct);

        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // DELETE /accounts/{accountId}
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeleteAccount(
        Guid accountId, [FromBody] DeleteAccountRequest request, ClaimsPrincipal user, AppDbContext db,
        BlobServiceClient blobService, ChannelService channels, ILoggerFactory loggerFactory,
        BusinessModeOptions businessMode, HttpContext http, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        var account = await db.Accounts.FirstOrDefaultAsync(a => a.AccountId == accountId, ct);
        if (account is null) return Results.NotFound();

        // Proof of possession of the account's own auth key — deletion is
        // irreversible, so a stolen JWT alone (which only proves the DEVICE's
        // identity) must not be enough. Same check LinkDevice uses.
        byte[] key;
        try { key = Convert.FromBase64String(request.AuthKey ?? ""); }
        catch (FormatException) { return Results.Forbid(); }
        if (key.Length == 0 || !await AccountEndpoints.VerifyAuthKeyAsync(key, account.AuthKeyHash))
            return Results.Forbid();

        // An organization owner cannot be deleted today — there is no
        // ownership-transfer flow (see Organization.cs), so deleting the
        // owner's account would orphan the organization. Membership rows of
        // OTHER organizations are append-only history and are left alone,
        // same reasoning as the device auditor check above.
        if (businessMode.Enabled)
        {
            var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();
            var ownsOrg = await auditDb.OrgMembers
                .AnyAsync(m => m.AccountId == accountId && m.Role == OrgRole.Owner && m.RemovedAt == null, ct);
            if (ownsOrg)
                return Results.Conflict(new { error = "Account owns an organization.", code = "account_owns_organization" });
        }

        // Channels owned by this account go through the existing soft-delete
        // path (tombstone + hub ChannelDeleted event) — reusing ChannelService
        // instead of duplicating that logic here. Each call commits on its
        // own; that is fine, these are independent aggregates from the account
        // row deleted in the transaction below.
        var ownedChannels = await db.Channels
            .Where(c => c.OwnerAccountId == accountId && c.DeletedAt == null)
            .ToListAsync(ct);
        foreach (var channel in ownedChannels)
            await channels.DeleteChannelAsync(channel, ct);

        // Backup blob paths are needed AFTER the DB transaction commits (Blob
        // deletion happens post-commit, see below) — capture them first.
        var backupBlobPaths = await db.Backups
            .Where(b => b.AccountId == accountId)
            .Select(b => b.BlobPath)
            .ToListAsync(ct);

        await using (var tx = await db.Database.BeginTransactionAsync(ct))
        {
            // Devices themselves are NOT deleted — losing account registration
            // just makes them anonymous again, per the brief. Deleting the
            // Account row cascades AccountDevices (the links) and Backups
            // (metadata rows) — both configured OnDelete(Cascade) in AppDbContext.
            await db.Database.ExecuteSqlRawAsync(
                """DELETE FROM "Accounts" WHERE "AccountId" = @accountId""",
                [new NpgsqlParameter("@accountId", accountId)], ct);

            await tx.CommitAsync(ct);
        }

        // Blob deletion runs AFTER the DB commit: if it fails here the account
        // is already gone and cannot be un-deleted to retry cleanly, so a
        // failure leaves an orphaned blob for ops cleanup rather than
        // resurrecting account state to paper over a storage hiccup. It MUST
        // be logged: the blob is an (encrypted) backup of a data subject who
        // asked to be erased, and nothing else would ever point at it again.
        var logger = loggerFactory.CreateLogger("CallType.Api.Privacy");
        var containerClient = blobService.GetBlobContainerClient(BackupContainerName);
        foreach (var blobPath in backupBlobPaths)
        {
            var relativePath = blobPath.StartsWith($"{BackupContainerName}/")
                ? blobPath[($"{BackupContainerName}/".Length)..]
                : blobPath;
            try
            {
                await containerClient.GetBlobClient(relativePath).DeleteIfExistsAsync(cancellationToken: ct);
            }
            catch (Exception ex)
            {
                // Best-effort: the account row is already committed as deleted.
                // The path holds ids only (no e-mail, no content).
                logger.LogError(ex, "Backup blob {BlobPath} of deleted account {AccountId} could not be removed; delete it manually.",
                    relativePath, accountId);
            }
        }

        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // GET /accounts/{accountId}/export
    // -----------------------------------------------------------------------
    private static async Task<IResult> ExportAccount(
        Guid accountId, ClaimsPrincipal user, AppDbContext db,
        BusinessModeOptions businessMode, HttpContext http, CancellationToken ct)
    {
        if (!await AccountEndpoints.IsLinkedAsync(user, accountId, db, ct)) return Results.Forbid();

        var account = await db.Accounts.AsNoTracking().FirstOrDefaultAsync(a => a.AccountId == accountId, ct);
        if (account is null) return Results.NotFound();

        var deviceIds = await db.AccountDevices
            .Where(ad => ad.AccountId == accountId)
            .Select(ad => ad.DeviceId)
            .ToListAsync(ct);

        var devices = await db.AccountDevices
            .Where(ad => ad.AccountId == accountId)
            .Join(db.Devices, ad => ad.DeviceId, d => d.DeviceId, (ad, d) => new
            {
                deviceId = d.DeviceId,
                userHandle = d.UserHandle,
                createdAt = d.CreatedAt,
                lastSeenAt = d.LastSeenAt,
                isBot = d.IsBot,
                hasPushToken = d.PushToken != null,
                linkedAt = ad.LinkedAt
            })
            .ToListAsync(ct);

        var backups = await db.Backups
            .Where(b => b.AccountId == accountId)
            .Select(b => new { id = b.Id, blobPath = b.BlobPath, sizeBytes = b.SizeBytes, status = b.Status.ToString(), createdAt = b.CreatedAt })
            .ToListAsync(ct);

        var ownedChannels = await db.Channels
            .Where(c => c.OwnerAccountId == accountId)
            .Select(c => new { channelId = c.ChannelId, handle = c.Handle, name = c.Name, createdAt = c.CreatedAt, deletedAt = c.DeletedAt })
            .ToListAsync(ct);

        var administeredChannels = await db.ChannelAdmins
            .Where(a => deviceIds.Contains(a.DeviceId))
            .Select(a => new { channelId = a.ChannelId, addedAt = a.AddedAt })
            .ToListAsync(ct);

        var follows = await db.ChannelFollowers
            .Where(f => deviceIds.Contains(f.DeviceId))
            .Select(f => new { channelId = f.ChannelId })
            .ToListAsync(ct);

        // Reports filed BY the account's own devices — reporter identity is
        // otherwise never exposed by the API, but it is the subject's own data
        // here (GDPR export scope), so it is the one place ReporterDeviceId leaks.
        var reportsFiled = await db.ChannelReports
            .Where(r => deviceIds.Contains(r.ReporterDeviceId))
            .Select(r => new
            {
                reportId = r.Id, channelId = r.ChannelId, postId = r.PostId, reason = r.Reason, createdAt = r.CreatedAt,
                // Moderation fields: what the subject told us (category, contact
                // e-mail, good-faith statement) and the outcome of their report.
                // The operator's decision itself is an operator record, not
                // the reporter's personal data, so only its result is included.
                category = r.Category, contactEmail = r.ContactEmail, goodFaith = r.GoodFaith,
                status = r.Status, resolvedAt = r.ResolvedAt
            })
            .ToListAsync(ct);

        // Multi-device: the signed lists these devices are part of, as a
        // primary or as a companion. The payload is the subject's own data
        // (their device IDs and public keys).
        var deviceLists = await db.DeviceLists
            .Where(l => deviceIds.Contains(l.PrimaryDeviceId) || l.Members.Any(m => deviceIds.Contains(m.DeviceId)))
            .Select(l => new { primaryDeviceId = l.PrimaryDeviceId, version = l.Version, payload = l.Payload, updatedAt = l.UpdatedAt })
            .ToListAsync(ct);

        // Queued message bodies are never exported — they also belong to the
        // conversation peer(s), who have not consented to this export. Only
        // a per-device count, matching the "note" field below.
        var queuedCounts = await db.QueuedMessages
            .Where(m => deviceIds.Contains(m.RecipientId))
            .GroupBy(m => m.RecipientId)
            .Select(g => new { deviceId = g.Key, queuedMessageCount = g.Count() })
            .ToListAsync(ct);

        object? organizations = null;
        if (businessMode.Enabled)
        {
            var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();
            var memberships = await auditDb.OrgMembers.AsNoTracking()
                .Where(m => m.AccountId == accountId)
                .Select(m => new { organizationId = m.OrganizationId, role = m.Role.ToString(), addedAt = m.AddedAt, removedAt = m.RemovedAt })
                .ToListAsync(ct);
            var enrollments = await auditDb.OrgEnrollments.AsNoTracking()
                .Where(e => e.AccountId == accountId)
                .Select(e => new { organizationId = e.OrganizationId, deviceId = e.DeviceId, enrolledAt = e.EnrolledAt, revokedAt = e.RevokedAt })
                .ToListAsync(ct);
            organizations = new { memberships, enrollments };
        }

        return Results.Ok(new
        {
            account = new { accountId = account.AccountId, email = account.Email, createdAt = account.CreatedAt },
            devices,
            backups,
            channelsOwned = ownedChannels,
            channelsAdministered = administeredChannels,
            channelsFollowed = follows,
            channelReportsFiled = reportsFiled,
            deviceLists = deviceLists.Select(l => new { l.primaryDeviceId, l.version, payload = Convert.ToBase64String(l.payload), l.updatedAt }),
            queuedMessages = new
            {
                note = "Counts only — message bodies are opaque, end-to-end encrypted and also belong to the sender/recipient peer, so they are never included in an export.",
                perDevice = queuedCounts
            },
            organizations
        });
    }
}

// ---------------------------------------------------------------------------
// Request DTOs
// ---------------------------------------------------------------------------

public record DeleteAccountRequest(string? AuthKey);
