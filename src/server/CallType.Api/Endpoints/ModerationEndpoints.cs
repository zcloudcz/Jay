// ---------------------------------------------------------------------------
// ModerationEndpoints.cs - Operator API for channel moderation (/admin/*)
// ---------------------------------------------------------------------------
// Contract: docs/superpowers/specs/2026-11-05-channel-moderation-contract.md
// section 4; design D3/D4/D5. Consumed by the operator web (src/client/jay_admin)
// served under jay.zcloud.cz/admin/.
//
// WHO: an account in Moderation:OperatorAccountIds, or with a linked device
// whose handle is in Moderation:OperatorHandles, with TOTP MFA enabled.
// POST /admin/session trades e-mail + authKey + TOTP (or a backup code) for a
// short operator token (scope=moderation, sub = ACCOUNT id). Program.cs
// rejects that token outside /admin (401); the group filter below rejects a
// device token inside /admin (403 operator_token_required) and re-checks the
// allowlist on every call, so removing an account from the configuration
// cuts its live sessions too. With an empty allowlist a Program.cs
// middleware answers 404 for all of /admin before anything else runs.
//
// ANONYMITY: reporter device ids never leave this file. Subjects carry counts
// and categories; the case detail lists reasons and the contact e-mail the
// reporter volunteered, never who reported.
// ---------------------------------------------------------------------------

using System.Globalization;
using System.Security.Claims;
using System.Text;
using Azure.Storage.Blobs;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace CallType.Api.Endpoints;

public static class ModerationEndpoints
{
    private const int MaxReasonPreview = 280;

    public static WebApplication MapModerationEndpoints(this WebApplication app)
    {
        // Anonymous by design (it is the login), throttled like /accounts/login.
        app.MapPost("/admin/session", CreateSession).AllowAnonymous().RequireRateLimiting("auth");

        var group = app.MapGroup("/admin")
            .RequireAuthorization()
            .RequireRateLimiting("api")
            .AddEndpointFilter(RequireOperator);

        group.MapGet("/summary", Summary);
        group.MapGet("/reports", ListSubjects);
        group.MapGet("/subjects/{channelId:guid}", SubjectDetail);
        group.MapGet("/channels/{channelId:guid}/attachments/{name}", DownloadAttachment);
        group.MapPost("/decisions", CreateDecision);
        group.MapGet("/decisions", ListDecisions);
        group.MapGet("/channels", SearchChannels);
        return app;
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private static IResult Error(int status, string error, string code) =>
        Results.Json(new { error, code }, statusCode: status);

    private static Guid? OperatorId(ClaimsPrincipal user) =>
        Guid.TryParse(user.FindFirst("sub")?.Value, out var id) ? id : null;

    /// <summary>Group filter: operator token AND still on the allowlist.</summary>
    private static async ValueTask<object?> RequireOperator(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        var user = context.HttpContext.User;
        if (!user.HasClaim(JwtService.ScopeClaim, JwtService.ModerationScope))
            return Error(403, "This endpoint needs an operator token from POST /admin/session.", "operator_token_required");

        var services = context.HttpContext.RequestServices;
        var options = services.GetRequiredService<IOptions<ModerationOptions>>().Value;
        if (OperatorId(user) is not { } id ||
            !await IsOperatorAsync(id, options, services.GetRequiredService<AppDbContext>(), context.HttpContext.RequestAborted))
            return Error(403, "This account is not an operator.", "not_an_operator");

        return await next(context);
    }

    /// <summary>
    /// Allowlisted by account id, or by the handle of a device linked to the
    /// account right now. Deliberately NOT cached: it is one indexed lookup
    /// per operator call (a single operator, low traffic), and a cache would
    /// keep a session alive after its device is unlinked, which is exactly
    /// the revocation the per-call re-check exists for.
    /// </summary>
    internal static async Task<bool> IsOperatorAsync(
        Guid accountId, ModerationOptions options, AppDbContext db, CancellationToken ct)
    {
        if (options.OperatorAccountIds.Contains(accountId)) return true;
        var handles = options.NormalizedOperatorHandles();
        if (handles.Count == 0) return false;
        // Device.UserHandle is stored upper-case (see DeviceEndpoints.FindDeviceByHandle).
        return await db.AccountDevices.AsNoTracking()
            .AnyAsync(ad => ad.AccountId == accountId && handles.Contains(ad.Device.UserHandle), ct);
    }

    private static DateTimeOffset? ParseCursor(string? value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var ts)
            ? ts.ToUniversalTime()
            : null;

    // -----------------------------------------------------------------------
    // POST /admin/session (4.1)
    // -----------------------------------------------------------------------
    private static async Task<IResult> CreateSession(
        OperatorSessionRequest request, AppDbContext db, MfaEncryptionService encryption, TotpService totp,
        JwtService jwt, TimeProvider clock, IOptions<ModerationOptions> options, CancellationToken ct)
    {
        IResult InvalidCredentials() => Error(401, "Invalid credentials.", "invalid_credentials");

        if (string.IsNullOrWhiteSpace(request.Email) || string.IsNullOrWhiteSpace(request.AuthKey))
            return InvalidCredentials();

        // Same decoding as POST /accounts/login (the client's hex string is
        // valid base64 and is hashed as such), so one authKey works for both.
        byte[] authKey;
        try { authKey = Convert.FromBase64String(request.AuthKey); }
        catch (FormatException) { return InvalidCredentials(); }

        var email = request.Email.Trim().ToLowerInvariant();
        var account = await db.Accounts.AsNoTracking().FirstOrDefaultAsync(a => a.Email == email, ct);
        if (account is null || authKey.Length == 0 || !await AccountEndpoints.VerifyAuthKeyAsync(authKey, account.AuthKeyHash))
            return InvalidCredentials();

        // Only after valid credentials: before that, "not an operator" would
        // let anyone probe which e-mails belong to the operator.
        if (!await IsOperatorAsync(account.AccountId, options.Value, db, ct))
            return Error(403, "This account is not an operator.", "not_an_operator");

        if (!encryption.IsConfigured) return MfaEndpoints.NotConfigured();
        var mfa = await db.AccountMfas.AsNoTracking().SingleOrDefaultAsync(m => m.AccountId == account.AccountId, ct);
        // 403, not MfaEndpoints' 409: for the operator web this is a missing
        // permission (enable MFA in the app first), not a state conflict.
        if (mfa is not { Enabled: true })
            return Error(403, "Enable two-factor authentication for this account in the app first.", "mfa_not_enabled");
        if (mfa.LockedUntil is { } lockedUntil && lockedUntil > clock.GetUtcNow()) return MfaEndpoints.Locked();

        var consumed = await MfaEndpoints.TryConsumeCodeAsync(
            db, encryption, totp, mfa, request.Code, request.BackupCode, clock, ct);
        if (consumed.Failure is not null) return consumed.Failure;

        var (token, expiresAt) = jwt.GenerateOperatorToken(
            account.AccountId, TimeSpan.FromMinutes(Math.Max(1, options.Value.SessionMinutes)));
        return Results.Ok(new { token, expiresAt, accountId = account.AccountId, email = account.Email });
    }

    // -----------------------------------------------------------------------
    // GET /admin/summary (4.2)
    // -----------------------------------------------------------------------
    private static async Task<IResult> Summary(AppDbContext db, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var open = db.ChannelReports.AsNoTracking().Where(r => r.Status == ModerationService.StatusOpen);
        var monthAgo = now.AddDays(-30);

        return Results.Ok(new
        {
            openReports = await open.CountAsync(ct),
            openSubjects = await open.Select(r => new { r.ChannelId, r.PostId }).Distinct().CountAsync(ct),
            oldestOpenAt = await open.MinAsync(r => (DateTimeOffset?)r.CreatedAt, ct),
            suspendedChannels = await db.Channels.CountAsync(c => c.DeletedAt == null && c.SuspendedUntil > now, ct),
            decisionsLast30Days = await db.ModerationDecisions.CountAsync(d => d.CreatedAt > monthAgo, ct)
        });
    }

    // -----------------------------------------------------------------------
    // GET /admin/reports (4.3) - queue grouped by subject
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListSubjects(
        string? status, string? category, string? subjectType, string? cursor, string? before, string? after, int? limit,
        AppDbContext db, ModerationService moderation, ChannelService channels, CancellationToken ct)
    {
        status = string.IsNullOrWhiteSpace(status) ? "open" : status.Trim().ToLowerInvariant();
        if (status is not ("open" or "resolved" or "all"))
            return Error(400, "status must be open, resolved or all.", "invalid_status");
        if (category is not null && category is not ("illegal" or "terms" or "spam"))
            return Error(400, "category must be illegal, terms or spam.", "invalid_category");
        if (subjectType is not null && subjectType is not ("channel" or "post"))
            return Error(400, "subjectType must be channel or post.", "invalid_subject_type");
        var take = Math.Clamp(limit ?? 50, 1, 100);

        var reports = db.ChannelReports.AsNoTracking();
        if (subjectType == "channel") reports = reports.Where(r => r.PostId == null);
        if (subjectType == "post") reports = reports.Where(r => r.PostId != null);

        // One row per subject (channel without post, or one post), aggregated
        // in SQL. A subject is open while ANY of its reports is open.
        var subjects = reports
            .GroupBy(r => new { r.ChannelId, r.PostId })
            .Select(g => new
            {
                g.Key.ChannelId,
                g.Key.PostId,
                ReportCount = g.Count(),
                OpenCount = g.Count(r => r.Status == ModerationService.StatusOpen),
                Illegal = g.Count(r => r.Category == "illegal"),
                Terms = g.Count(r => r.Category == "terms"),
                Spam = g.Count(r => r.Category == "spam"),
                First = g.Min(r => r.CreatedAt),
                Last = g.Max(r => r.CreatedAt)
            });
        // Category filter = subjects with at least one report of that
        // category; the counts in the row still cover all its reports.
        if (category == "illegal") subjects = subjects.Where(s => s.Illegal > 0);
        if (category == "terms") subjects = subjects.Where(s => s.Terms > 0);
        if (category == "spam") subjects = subjects.Where(s => s.Spam > 0);

        // Tab counts follow the other filters but not the status.
        var openCount = await subjects.CountAsync(s => s.OpenCount > 0, ct);
        var resolvedCount = await subjects.CountAsync(s => s.OpenCount == 0, ct);

        // Keyset paging. Open = oldest first (work the backlog FIFO), cursor is
        // the last item's firstReportedAt; otherwise newest first by
        // lastReportedAt. "cursor" is the documented parameter, before/after
        // are accepted as the contract's aliases for the same value.
        var position = ParseCursor(cursor ?? (status == "open" ? after : before));
        var rows = status == "open"
            ? await subjects.Where(s => s.OpenCount > 0)
                .Where(s => position == null || s.First > position)
                .OrderBy(s => s.First).Take(take + 1).ToListAsync(ct)
            : await subjects.Where(s => status == "all" || s.OpenCount == 0)
                .Where(s => position == null || s.Last < position)
                .OrderByDescending(s => s.Last).Take(take + 1).ToListAsync(ct);

        var hasMore = rows.Count > take;
        rows = rows.Take(take).ToList();

        var channelIds = rows.Select(r => r.ChannelId).Distinct().ToList();
        var postIds = rows.Where(r => r.PostId != null).Select(r => r.PostId!.Value).ToList();

        var channelMap = await db.Channels.AsNoTracking()
            .Where(c => channelIds.Contains(c.ChannelId)).ToDictionaryAsync(c => c.ChannelId, ct);
        var postMap = await db.ChannelPosts.AsNoTracking()
            .Where(p => postIds.Contains(p.PostId)).ToDictionaryAsync(p => p.PostId, ct);
        var bots = await channels.BotAuthorsAsync(postMap.Values.Select(p => p.AuthorDeviceId), ct);
        var owners = await moderation.OwnerHandlesAsync(channelMap.Values, ct);

        // Latest reason per subject, picked in memory: bounded by the page's
        // channels and cheaper to read than a per-row lateral subquery.
        var reasons = await db.ChannelReports.AsNoTracking()
            .Where(r => channelIds.Contains(r.ChannelId))
            .OrderByDescending(r => r.CreatedAt)
            .Select(r => new { r.ChannelId, r.PostId, r.Reason })
            .ToListAsync(ct);
        var decisions = await db.ModerationDecisions.AsNoTracking()
            .Where(d => channelIds.Contains(d.ChannelId) && d.Action != ModerationService.Dismiss)
            .OrderByDescending(d => d.CreatedAt)
            .ToListAsync(ct);

        var now = DateTimeOffset.UtcNow;
        var items = rows.Select(s =>
        {
            var latest = reasons.FirstOrDefault(r => r.ChannelId == s.ChannelId && r.PostId == s.PostId)?.Reason ?? "";
            channelMap.TryGetValue(s.ChannelId, out var channel);
            ChannelPost? post = s.PostId is { } pid && postMap.TryGetValue(pid, out var p) ? p : null;
            return new
            {
                subjectType = s.PostId is null ? "channel" : "post",
                channelId = s.ChannelId,
                postId = s.PostId,
                status = s.OpenCount > 0 ? "open" : "resolved",
                reportCount = s.ReportCount,
                categories = new { illegal = s.Illegal, terms = s.Terms, spam = s.Spam },
                firstReportedAt = s.First,
                lastReportedAt = s.Last,
                latestReason = latest.Length > MaxReasonPreview ? latest[..MaxReasonPreview] : latest,
                channel = channel is null
                    ? null
                    : ModerationService.ChannelSummaryDto(channel, owners.GetValueOrDefault(channel.OwnerDeviceId), now),
                post = post is null ? null : ModerationService.PostSummaryDto(post, bots.Contains(post.AuthorDeviceId)),
                priorDecisions = decisions.Where(d => d.ChannelId == s.ChannelId).Select(ModerationService.DecisionDto).ToList()
            };
        }).ToList();

        string? nextCursor = null;
        if (hasMore && rows.Count > 0)
            nextCursor = (status == "open" ? rows[^1].First : rows[^1].Last).ToString("O", CultureInfo.InvariantCulture);

        return Results.Ok(new { items, counts = new { open = openCount, resolved = resolvedCount }, nextCursor });
    }

    // -----------------------------------------------------------------------
    // GET /admin/subjects/{channelId}?postId= (4.4) - case detail
    // -----------------------------------------------------------------------
    private static async Task<IResult> SubjectDetail(
        Guid channelId, Guid? postId, AppDbContext db, ModerationService moderation, ChannelService channels,
        CancellationToken ct)
    {
        // Deleted channels included: the operator reviews terminated ones too.
        var channel = await db.Channels.AsNoTracking().FirstOrDefaultAsync(c => c.ChannelId == channelId, ct);
        if (channel is null) return Error(404, "Channel not found.", "channel_not_found");

        ChannelPost? post = null;
        List<ChannelPost> context;
        if (postId is { } pid)
        {
            post = await db.ChannelPosts.AsNoTracking().FirstOrDefaultAsync(p => p.PostId == pid && p.ChannelId == channelId, ct);
            // A post removed by retention still has its reports; only a
            // subject that never existed is a 404.
            if (post is null && !await db.ChannelReports.AnyAsync(r => r.ChannelId == channelId && r.PostId == pid, ct))
                return Error(404, "Post not found.", "post_not_found");

            if (post is null)
            {
                context = [];
            }
            else
            {
                // Up to 2 posts before and 2 after, chronological, so the
                // operator sees what the reported post was replying to.
                var beforePosts = await db.ChannelPosts.AsNoTracking()
                    .Where(p => p.ChannelId == channelId && p.CreatedAt < post.CreatedAt)
                    .OrderByDescending(p => p.CreatedAt).Take(2).ToListAsync(ct);
                var afterPosts = await db.ChannelPosts.AsNoTracking()
                    .Where(p => p.ChannelId == channelId && p.CreatedAt > post.CreatedAt)
                    .OrderBy(p => p.CreatedAt).Take(2).ToListAsync(ct);
                context = beforePosts.AsEnumerable().Reverse().Concat(afterPosts).ToList();
            }
        }
        else
        {
            context = await db.ChannelPosts.AsNoTracking()
                .Where(p => p.ChannelId == channelId)
                .OrderByDescending(p => p.CreatedAt).Take(10).ToListAsync(ct);
        }

        var bots = await channels.BotAuthorsAsync(
            context.Select(p => p.AuthorDeviceId).Concat(post is null ? [] : [post.AuthorDeviceId]), ct);
        var owners = await moderation.OwnerHandlesAsync([channel], ct);

        // Reports of THIS subject only (a channel case = reports without a post).
        var reports = await db.ChannelReports.AsNoTracking()
            .Where(r => r.ChannelId == channelId && r.PostId == postId)
            .OrderByDescending(r => r.CreatedAt)
            .Take(200)
            .Select(r => new
            {
                reportId = r.Id,
                category = r.Category,
                reason = r.Reason,
                contactEmail = r.ContactEmail,
                goodFaith = r.GoodFaith,
                createdAt = r.CreatedAt,
                status = r.Status
            })
            .ToListAsync(ct);

        var decisions = await db.ModerationDecisions.AsNoTracking()
            .Where(d => d.ChannelId == channelId)
            .OrderByDescending(d => d.CreatedAt)
            .ToListAsync(ct);

        return Results.Ok(new
        {
            channel = ModerationService.ChannelSummaryDto(
                channel, owners.GetValueOrDefault(channel.OwnerDeviceId), DateTimeOffset.UtcNow),
            post = post is null ? null : ModerationService.PostSummaryDto(post, bots.Contains(post.AuthorDeviceId)),
            context = context.Select(p => ModerationService.PostSummaryDto(p, bots.Contains(p.AuthorDeviceId))),
            reports,
            decisions = decisions.Select(ModerationService.DecisionDto)
        });
    }

    // -----------------------------------------------------------------------
    // GET /admin/channels/{channelId}/attachments/{name} (4.5)
    // -----------------------------------------------------------------------
    private static async Task<IResult> DownloadAttachment(
        Guid channelId, string name, HttpContext http, BlobServiceClient blobService, CancellationToken ct)
    {
        // Same strict name rule and served content type as the user route;
        // no channel lookup because deleted/suspended channels are in scope.
        if (!ChannelEndpoints.AttachmentName().IsMatch(name)) return Error(404, "Attachment not found.", "attachment_not_found");

        var blob = blobService.GetBlobContainerClient(ChannelEndpoints.ContainerName).GetBlobClient($"{channelId}/{name}");
        if (!await blob.ExistsAsync(ct)) return Error(404, "Attachment not found.", "attachment_not_found");

        var contentType = ChannelEndpoints.ImageExtensions.First(e => e.Value == name[(name.LastIndexOf('.') + 1)..]).Key;
        http.Response.Headers.XContentTypeOptions = "nosniff";
        // Reported material: never let a shared cache keep a copy.
        http.Response.Headers.CacheControl = "no-store";

        var download = await blob.DownloadStreamingAsync(cancellationToken: ct);
        return Results.Stream(download.Value.Content, contentType);
    }

    // -----------------------------------------------------------------------
    // POST /admin/decisions (4.6)
    // -----------------------------------------------------------------------
    private static async Task<IResult> CreateDecision(
        DecisionBody body, ClaimsPrincipal user, ModerationService moderation, CancellationToken ct)
    {
        var outcome = await moderation.ApplyAsync(new DecisionRequest(
            body.ChannelId ?? Guid.Empty, body.PostId, body.Action, body.Ground, body.Rule,
            body.LegalGround, body.Explanation, body.SuspendDays), OperatorId(user)!.Value, ct);

        return outcome.Decision is { } decision
            ? Results.Created($"/admin/decisions/{decision.Id}", ModerationService.DecisionDto(decision))
            : Error(outcome.Status, outcome.Error!, outcome.Code!);
    }

    // -----------------------------------------------------------------------
    // GET /admin/channels?q=&limit= (4.7)
    // -----------------------------------------------------------------------
    private static async Task<IResult> SearchChannels(
        string? q, int? limit, AppDbContext db, ModerationService moderation, CancellationToken ct)
    {
        var take = Math.Clamp(limit ?? 20, 1, 50);
        var query = db.Channels.AsNoTracking();
        if (!string.IsNullOrWhiteSpace(q))
        {
            // Escape LIKE wildcards so "50%" searches for the text, not a
            // pattern. The escape character is passed explicitly: Npgsql
            // otherwise emits ESCAPE '' and the backslashes would be literal.
            var term = q.Trim().Replace(@"\", @"\\").Replace("%", @"\%").Replace("_", @"\_");
            query = query.Where(c => EF.Functions.ILike(c.Handle, $"%{term}%", @"\") ||
                                     EF.Functions.ILike(c.Name, $"%{term}%", @"\"));
        }

        var list = await query.OrderByDescending(c => c.CreatedAt).Take(take).ToListAsync(ct);
        var owners = await moderation.OwnerHandlesAsync(list, ct);
        var now = DateTimeOffset.UtcNow;
        return Results.Ok(list.Select(c => ModerationService.ChannelSummaryDto(c, owners.GetValueOrDefault(c.OwnerDeviceId), now)));
    }

    // -----------------------------------------------------------------------
    // GET /admin/decisions?before=&limit=&format=json|csv (4.8)
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListDecisions(
        string? before, int? limit, string? format, AppDbContext db, CancellationToken ct)
    {
        var csv = string.Equals(format, "csv", StringComparison.OrdinalIgnoreCase);
        if (format is not null && !csv && !string.Equals(format, "json", StringComparison.OrdinalIgnoreCase))
            return Error(400, "format must be json or csv.", "invalid_format");

        // The CSV is the audit export, so it may pull a much larger page than
        // the JSON list the web pages through.
        var take = csv ? Math.Clamp(limit ?? 1000, 1, 10000) : Math.Clamp(limit ?? 50, 1, 100);
        var query = db.ModerationDecisions.AsNoTracking();
        if (ParseCursor(before) is { } cursor) query = query.Where(d => d.CreatedAt < cursor);
        var decisions = await query.OrderByDescending(d => d.CreatedAt).ThenByDescending(d => d.Id).Take(take).ToListAsync(ct);

        if (!csv) return Results.Ok(decisions.Select(ModerationService.DecisionDto));

        var sb = new StringBuilder();
        sb.Append("decisionId,action,postId,ground,rule,legalGround,explanation,suspendedUntil,basedOnReports,")
          .Append("automated,createdAt,operatorAccountId,reportCount,channelId\n");
        foreach (var d in decisions)
        {
            string[] cells =
            [
                d.Id.ToString(CultureInfo.InvariantCulture), d.Action, d.PostId?.ToString() ?? "", d.Ground ?? "",
                d.Rule ?? "", d.LegalGround ?? "", d.Explanation, d.SuspendedUntil?.ToString("O", CultureInfo.InvariantCulture) ?? "",
                d.ReportCount > 0 ? "true" : "false", "false", d.CreatedAt.ToString("O", CultureInfo.InvariantCulture),
                d.OperatorAccountId.ToString(), d.ReportCount.ToString(CultureInfo.InvariantCulture), d.ChannelId.ToString()
            ];
            // Same formula-injection guard as the organization audit export:
            // explanations are free text an operator may later open in Excel.
            sb.Append(string.Join(',', cells.Select(OrganizationEndpoints.EscapeCsv))).Append('\n');
        }
        return Results.Text(sb.ToString(), "text/csv");
    }
}

// ---------------------------------------------------------------------------
// Request DTOs
// ---------------------------------------------------------------------------

public record OperatorSessionRequest(string? Email, string? AuthKey, string? Code, string? BackupCode);

public record DecisionBody(
    Guid? ChannelId, Guid? PostId, string? Action, string? Ground, string? Rule,
    string? LegalGround, string? Explanation, int? SuspendDays);
