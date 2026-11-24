// ---------------------------------------------------------------------------
// UserSafetyEndpoints.cs - block and report a USER (spec 2026-11-14-go-live)
// ---------------------------------------------------------------------------
// Apple guideline 1.2 asks apps with user content for a way to block abusive
// users and to report objectionable content. Channels have had both since the
// channel moderation work; this file is the same for people:
//   PUT    /blocks/{deviceId}       block the identity of a device (S2)
//   DELETE /blocks/{deviceId}       lift it (S3)
//   GET    /blocks                  the caller identity's block list (S4)
//   POST   /users/{deviceId}/report report a user to the operator (S7)
//   GET    /admin/user-reports      operator queue (S8, mapped in ModerationEndpoints)
//   PUT    /admin/user-reports/{id}/status
// Everything is keyed by IDENTITY (primary device id): a person who blocks
// from the laptop blocks on the phone too, and a blocked person cannot get
// around it from a companion.
// ---------------------------------------------------------------------------

using System.Globalization;
using System.Security.Claims;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using Npgsql;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;

namespace CallType.Api.Endpoints;

public static class UserSafetyEndpoints
{
    private const int MaxReasonLength = 1000;
    private const int MaxEvidenceMessages = 20;
    private const int MaxEvidenceText = 4000;

    public static WebApplication MapUserSafetyEndpoints(this WebApplication app)
    {
        var blocks = app.MapGroup("/blocks").RequireAuthorization().RequireRateLimiting("api");
        blocks.MapGet("", ListBlocks);
        blocks.MapPut("/{deviceId:guid}", Block);
        blocks.MapDelete("/{deviceId:guid}", Unblock);

        app.MapPost("/users/{deviceId:guid}/report", Report).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static IResult Error(int status, string error, string code) =>
        Results.Json(new { error, code }, statusCode: status);

    // -----------------------------------------------------------------------
    // PUT /blocks/{deviceId}
    // -----------------------------------------------------------------------
    private static async Task<IResult> Block(
        Guid deviceId, ClaimsPrincipal user, AppDbContext db, DeviceListService deviceLists, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (!await db.Devices.AnyAsync(d => d.DeviceId == deviceId, ct))
            return Error(404, "Device not found.", "unknown_device");

        var (blocker, blocked) = await deviceLists.PrimariesOfAsync(me, deviceId, ct);
        if (blocker == blocked) return Error(400, "You cannot block yourself.", "cannot_block_self");

        if (await db.UserBlocks.AnyAsync(b => b.BlockerPrimaryId == blocker && b.BlockedPrimaryId == blocked, ct))
            return Results.NoContent();
        if (await db.UserBlocks.CountAsync(b => b.BlockerPrimaryId == blocker, ct) >= UserBlock.MaxPerIdentity)
            return Error(400, $"At most {UserBlock.MaxPerIdentity} blocks.", "block_limit");

        // ON CONFLICT DO NOTHING: two own devices blocking the same person at
        // once must both get 204, not one of them a unique-index 500.
        await db.Database.ExecuteSqlRawAsync(
            """
            INSERT INTO "UserBlocks" ("BlockerPrimaryId", "BlockedPrimaryId", "CreatedAt")
            VALUES (@blocker, @blocked, @now)
            ON CONFLICT ("BlockerPrimaryId", "BlockedPrimaryId") DO NOTHING
            """,
            [new NpgsqlParameter("@blocker", blocker), new NpgsqlParameter("@blocked", blocked),
             new NpgsqlParameter("@now", DateTimeOffset.UtcNow)], ct);

        // D3: what the blocked identity already queued for us must not arrive
        // either. Only undelivered rows: an acknowledged row is a receipt that
        // stops a sender retry from re-queuing delivered content.
        var senderDevices = await deviceLists.DevicesOfAsync([blocked], ct);
        var ownDevices = await deviceLists.DevicesOfAsync([blocker], ct);
        await db.QueuedMessages
            .Where(m => m.AcknowledgedAt == null && senderDevices.Contains(m.SenderId) && ownDevices.Contains(m.RecipientId))
            .ExecuteDeleteAsync(ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // DELETE /blocks/{deviceId}
    // -----------------------------------------------------------------------
    private static async Task<IResult> Unblock(
        Guid deviceId, ClaimsPrincipal user, AppDbContext db, DeviceListService deviceLists, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        var (blocker, blocked) = await deviceLists.PrimariesOfAsync(me, deviceId, ct);
        await db.UserBlocks
            .Where(b => b.BlockerPrimaryId == blocker && b.BlockedPrimaryId == blocked)
            .ExecuteDeleteAsync(ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // GET /blocks
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListBlocks(
        ClaimsPrincipal user, AppDbContext db, DeviceListService deviceLists, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        var blocker = await deviceLists.PrimaryOfAsync(me, ct);
        var rows = await db.UserBlocks.AsNoTracking()
            .Where(b => b.BlockerPrimaryId == blocker)
            .OrderByDescending(b => b.CreatedAt)
            .Join(db.Devices, b => b.BlockedPrimaryId, d => d.DeviceId, (b, d) => new
            {
                deviceId = d.DeviceId,
                userHandle = d.UserHandle,
                displayName = d.DisplayName,
                isBot = d.IsBot,
                createdAt = b.CreatedAt
            })
            .ToListAsync(ct);
        return Results.Ok(new { blocks = rows });
    }

    // -----------------------------------------------------------------------
    // POST /users/{deviceId}/report
    // -----------------------------------------------------------------------
    private static async Task<IResult> Report(
        Guid deviceId, UserReportRequest request, ClaimsPrincipal user, AppDbContext db,
        DeviceListService deviceLists, IOptions<ModerationOptions> options, ILoggerFactory loggerFactory,
        CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (!await db.Devices.AnyAsync(d => d.DeviceId == deviceId, ct))
            return Error(404, "Device not found.", "unknown_device");
        var (reporter, reported) = await deviceLists.PrimariesOfAsync(me, deviceId, ct);
        if (reporter == reported) return Error(400, "You cannot report yourself.", "cannot_report_self");

        // Same categories, e-mail and good-faith rules as channel reports, so
        // the app uses one dialog for both.
        var category = request.Category?.Trim().ToLowerInvariant() ?? "terms";
        if (category is not ("illegal" or "terms" or "spam"))
            return Error(400, "category must be illegal, terms or spam.", "invalid_category");
        var reason = request.Reason?.Trim() ?? "";
        if (reason.Length is 0 or > MaxReasonLength)
            return Error(400, $"reason must be 1-{MaxReasonLength} characters.", "invalid_reason");
        var contactEmail = string.IsNullOrWhiteSpace(request.ContactEmail) ? null : request.ContactEmail.Trim();
        if (contactEmail is not null && (contactEmail.Length > 254 || !contactEmail.Contains('@')))
            return Error(400, "contactEmail must be an e-mail address of at most 254 characters.", "invalid_contact");
        var goodFaith = request.GoodFaith ?? false;
        if (category == "illegal" && !goodFaith)
            return Error(400, "An illegal-content report requires the good-faith confirmation.", "good_faith_required");

        var messages = request.Messages ?? [];
        if (messages.Count > MaxEvidenceMessages ||
            messages.Any(m => string.IsNullOrWhiteSpace(m.Text) || m.Text.Length > MaxEvidenceText ||
                              (m.MessageId?.Length ?? 0) > 64))
            return Error(400, $"messages: at most {MaxEvidenceMessages}, each text 1-{MaxEvidenceText} characters.",
                "invalid_evidence");

        // Daily budget per IDENTITY (every own device counts): reports create
        // operator work, and a second device must not double the budget.
        var ownDevices = await deviceLists.DevicesOfAsync([reporter], ct);
        var since = DateTimeOffset.UtcNow.AddDays(-1);
        var recent = await db.UserReports.CountAsync(
            r => ownDevices.Contains(r.ReporterDeviceId) && r.CreatedAt > since, ct);
        if (recent >= options.Value.MaxUserReportsPerDay)
            return Error(429, "Too many reports, try again later.", "report_limit_reached");

        var handle = await db.Devices.Where(d => d.DeviceId == reported).Select(d => d.UserHandle)
            .FirstOrDefaultAsync(ct) ?? "";
        var now = DateTimeOffset.UtcNow;
        var report = new UserReport
        {
            ReporterDeviceId = me,
            ReportedPrimaryId = reported,
            ReportedHandle = handle,
            GroupId = request.GroupId,
            Category = category,
            Reason = reason,
            EvidenceJson = JsonSerializer.Serialize(messages.Select(m => new
            {
                messageId = m.MessageId,
                sentAt = m.SentAt,
                text = m.Text
            })),
            ContactEmail = contactEmail,
            GoodFaith = goodFaith,
            Status = "open",
            // Microseconds like channel reports: the receipt must equal the stored value.
            CreatedAt = new DateTimeOffset(now.Ticks - now.Ticks % 10, TimeSpan.Zero)
        };
        db.UserReports.Add(report);
        await db.SaveChangesAsync(ct);

        // No mail infrastructure (see ChannelService.ReportAsync): the operator
        // alerts on this structured log line. Ids only, never the evidence.
        loggerFactory.CreateLogger("CallType.Api.UserSafety").LogWarning(
            "User report {ReportId} filed: category {Category}, evidence messages {Count}",
            report.Id, category, messages.Count);
        return Results.Ok(new { reportId = report.Id, createdAt = report.CreatedAt });
    }

    // -----------------------------------------------------------------------
    // GET /admin/user-reports (operator, S8)
    // -----------------------------------------------------------------------
    internal static async Task<IResult> AdminListUserReports(
        string? status, string? before, int? limit, AppDbContext db, CancellationToken ct)
    {
        status = string.IsNullOrWhiteSpace(status) ? "open" : status.Trim().ToLowerInvariant();
        if (status is not ("open" or "dismissed" or "actioned" or "all"))
            return Error(400, "status must be open, dismissed, actioned or all.", "invalid_status");
        var take = Math.Clamp(limit ?? 50, 1, 100);

        var query = db.UserReports.AsNoTracking();
        if (status != "all") query = query.Where(r => r.Status == status);
        if (DateTimeOffset.TryParse(before, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var cursor))
        {
            var utc = cursor.ToUniversalTime();
            query = query.Where(r => r.CreatedAt < utc);
        }
        var reports = await query.OrderByDescending(r => r.CreatedAt).Take(take).ToListAsync(ct);

        var reportedIds = reports.Select(r => r.ReportedPrimaryId).Distinct().ToList();
        var devices = await db.Devices.AsNoTracking()
            .Where(d => reportedIds.Contains(d.DeviceId))
            .Select(d => new { d.DeviceId, d.DisplayName })
            .ToDictionaryAsync(d => d.DeviceId, ct);
        var counts = await db.UserReports.AsNoTracking()
            .Where(r => reportedIds.Contains(r.ReportedPrimaryId))
            .GroupBy(r => r.ReportedPrimaryId)
            .Select(g => new { g.Key, Count = g.Count() })
            .ToDictionaryAsync(g => g.Key, g => g.Count, ct);

        // ReporterDeviceId is deliberately absent (D8).
        var items = reports.Select(r => new
        {
            reportId = r.Id,
            reportedDeviceId = r.ReportedPrimaryId,
            reportedHandle = r.ReportedHandle,
            reportedDisplayName = devices.TryGetValue(r.ReportedPrimaryId, out var d) ? d.DisplayName : null,
            reportedExists = devices.ContainsKey(r.ReportedPrimaryId),
            groupId = r.GroupId,
            category = r.Category,
            reason = r.Reason,
            messages = JsonSerializer.Deserialize<JsonElement>(r.EvidenceJson),
            contactEmail = r.ContactEmail,
            goodFaith = r.GoodFaith,
            status = r.Status,
            createdAt = r.CreatedAt,
            resolvedAt = r.ResolvedAt,
            reportsAgainstSameUser = counts.GetValueOrDefault(r.ReportedPrimaryId)
        });
        return Results.Ok(new { items });
    }

    // -----------------------------------------------------------------------
    // PUT /admin/user-reports/{id}/status (operator, S8)
    // -----------------------------------------------------------------------
    internal static async Task<IResult> AdminSetUserReportStatus(
        long id, UserReportStatusRequest request, AppDbContext db, CancellationToken ct)
    {
        var status = request.Status?.Trim().ToLowerInvariant();
        if (status is not ("dismissed" or "actioned"))
            return Error(400, "status must be dismissed or actioned.", "invalid_status");
        var updated = await db.UserReports.Where(r => r.Id == id)
            .ExecuteUpdateAsync(s => s
                .SetProperty(r => r.Status, status)
                .SetProperty(r => r.ResolvedAt, DateTimeOffset.UtcNow), ct);
        return updated == 0 ? Error(404, "Report not found.", "report_not_found") : Results.NoContent();
    }
}

public record UserReportEvidence(string? MessageId, DateTimeOffset? SentAt, string? Text);

public record UserReportRequest(
    string? Category, string? Reason, string? ContactEmail = null, bool? GoodFaith = null,
    Guid? GroupId = null, List<UserReportEvidence>? Messages = null);

public record UserReportStatusRequest(string? Status);
