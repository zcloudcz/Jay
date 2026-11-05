// ---------------------------------------------------------------------------
// ModerationService.cs - Operator decisions on channels and posts
// ---------------------------------------------------------------------------
// Business rules of POST /admin/decisions (moderation contract 4.6) plus the
// JSON shapes shared by the operator API and the owner's statements of
// reasons (GET /channels/{id}/moderation), so both always show the same
// fields for the same decision.
//
// Every decision writes exactly one append-only ModerationDecision row and
// resolves the reports it covers in the SAME transaction: a report is never
// "actioned" without the decision that actioned it, and vice versa. Hub
// events (tombstone, ChannelDeleted) go out only after the commit.
//
// ANONYMITY: nothing built here carries a ReporterDeviceId. The operator sees
// counts, categories, reasons and the contact e-mail a reporter volunteered.
// ---------------------------------------------------------------------------

using System.Text.RegularExpressions;
using CallType.Api.Data;
using CallType.Api.Models;
using Microsoft.EntityFrameworkCore;

namespace CallType.Api.Services;

/// <summary>Validated input of one decision.</summary>
public record DecisionRequest(
    Guid ChannelId, Guid? PostId, string? Action, string? Ground, string? Rule,
    string? LegalGround, string? Explanation, int? SuspendDays);

/// <summary>Result of ApplyAsync: either a decision or an error (status, code, text).</summary>
public record DecisionOutcome(ModerationDecision? Decision, int Status, string? Code, string? Error);

public partial class ModerationService(AppDbContext db, ChannelService channels)
{
    public const string Dismiss = "dismiss";
    public const string RemovePost = "remove_post";
    public const string SuspendChannel = "suspend_channel";
    public const string TerminateChannel = "terminate_channel";
    public const string RestoreChannel = "restore_channel";

    public static readonly IReadOnlySet<string> Actions =
        new HashSet<string> { Dismiss, RemovePost, SuspendChannel, TerminateChannel, RestoreChannel };

    public const string StatusOpen = "open";
    public const string StatusDismissed = "dismissed";
    public const string StatusActioned = "actioned";

    // Exactly K1..K10 (docs/legal/pravidla-kanalu.md); "K01" or "K11" are not rules.
    [GeneratedRegex("^K([1-9]|10)$")]
    private static partial Regex RuleId();

    public static bool IsRule(string? rule) => rule is not null && RuleId().IsMatch(rule);

    // -----------------------------------------------------------------------
    // DTOs (contract 3 Statement, 4.3 ChannelSummary/PostSummary, 4.4 Decision)
    // -----------------------------------------------------------------------

    /// <summary>What the channel's owner/admins see: the statement of reasons (DSA Art. 17).</summary>
    public static object StatementDto(ModerationDecision d) => new
    {
        decisionId = d.Id,
        action = d.Action,
        postId = d.PostId,
        ground = d.Ground,
        rule = d.Rule,
        legalGround = d.LegalGround,
        explanation = d.Explanation,
        suspendedUntil = d.SuspendedUntil,
        basedOnReports = d.ReportCount > 0,
        // Art. 17(3)(c): every decision is made by a human (rule 5 of the rules).
        automated = false,
        createdAt = d.CreatedAt
    };

    /// <summary>Operator view = statement + who decided and on how many reports.</summary>
    public static object DecisionDto(ModerationDecision d) => new
    {
        decisionId = d.Id,
        action = d.Action,
        postId = d.PostId,
        ground = d.Ground,
        rule = d.Rule,
        legalGround = d.LegalGround,
        explanation = d.Explanation,
        suspendedUntil = d.SuspendedUntil,
        basedOnReports = d.ReportCount > 0,
        automated = false,
        createdAt = d.CreatedAt,
        operatorAccountId = d.OperatorAccountId,
        reportCount = d.ReportCount,
        channelId = d.ChannelId
    };

    public static object ChannelSummaryDto(Channel c, string? ownerHandle, DateTimeOffset now)
    {
        var suspended = c.IsSuspended(now);
        return new
        {
            channelId = c.ChannelId,
            handle = c.Handle,
            name = c.Name,
            description = c.Description,
            followerCount = c.FollowerCount,
            status = suspended ? "suspended" : "active",
            suspendedUntil = suspended ? c.SuspendedUntil : null,
            deleted = c.DeletedAt is not null,
            createdAt = c.CreatedAt,
            ownerHandle
        };
    }

    /// <summary>
    /// Post for the operator. Unlike the follower DTO a soft-deleted post keeps
    /// its body here: the operator has to judge the content even if the
    /// channel's admin deleted it after it was reported.
    /// </summary>
    public static object PostSummaryDto(ChannelPost p, bool byBot) => new
    {
        postId = p.PostId,
        kind = ChannelService.KindToApi(p.Kind),
        body = p.Body,
        attachmentBlobPath = p.AttachmentBlobPath,
        createdAt = p.CreatedAt,
        deleted = p.DeletedAt is not null,
        byBot
    };

    /// <summary>Owner device handles for a set of channels (ChannelSummary.ownerHandle).</summary>
    public async Task<Dictionary<Guid, string>> OwnerHandlesAsync(IEnumerable<Channel> list, CancellationToken ct)
    {
        var ownerDevices = list.Select(c => c.OwnerDeviceId).Distinct().ToList();
        return await db.Devices.AsNoTracking()
            .Where(d => ownerDevices.Contains(d.DeviceId))
            .ToDictionaryAsync(d => d.DeviceId, d => d.UserHandle, ct);
    }

    // -----------------------------------------------------------------------
    // POST /admin/decisions
    // -----------------------------------------------------------------------

    private static DecisionOutcome Fail(int status, string code, string error) => new(null, status, code, error);

    /// <summary>
    /// Validates and applies one decision. Validation order follows the
    /// contract's list so the same bad request always yields the same code.
    /// </summary>
    public async Task<DecisionOutcome> ApplyAsync(DecisionRequest request, Guid operatorAccountId, CancellationToken ct)
    {
        var action = request.Action?.Trim().ToLowerInvariant() ?? "";
        if (!Actions.Contains(action)) return Fail(400, "invalid_action", "Unknown action.");

        if (action == RemovePost && request.PostId is null)
            return Fail(400, "post_required", "remove_post needs a postId.");
        if (action is (SuspendChannel or TerminateChannel or RestoreChannel) && request.PostId is not null)
            return Fail(400, "post_not_allowed", "This action applies to the whole channel; omit postId.");

        // dismiss and restore change nothing for the owner that needs a legal
        // basis, so they take no ground (a sent one is ignored, not stored).
        string? ground = null, rule = null, legalGround = null;
        if (action is not (Dismiss or RestoreChannel))
        {
            ground = request.Ground?.Trim().ToLowerInvariant();
            if (ground is not ("terms" or "illegal"))
                return Fail(400, "invalid_ground", "ground must be terms or illegal.");
            if (ground == "terms")
            {
                rule = request.Rule?.Trim().ToUpperInvariant();
                if (!IsRule(rule)) return Fail(400, "invalid_rule", "rule must be one of K1..K10.");
            }
            else
            {
                legalGround = request.LegalGround?.Trim() ?? "";
                if (legalGround.Length is 0 or > 300)
                    return Fail(400, "legal_ground_required", "legalGround must be 1-300 characters.");
            }
        }

        var explanation = request.Explanation?.Trim() ?? "";
        if (explanation.Length is 0 or > 2000)
            return Fail(400, "explanation_required", "explanation must be 1-2000 characters.");

        if (action == SuspendChannel && request.SuspendDays is not (>= 1 and <= 365))
            return Fail(400, "invalid_suspend_days", "suspendDays must be 1-365.");

        // Deleted (terminated) channels are included: their leftover reports
        // still have to be closed.
        var channel = await db.Channels.FirstOrDefaultAsync(c => c.ChannelId == request.ChannelId, ct);
        if (channel is null) return Fail(404, "channel_not_found", "Channel not found.");

        ChannelPost? post = null;
        if (request.PostId is { } postId)
        {
            post = await db.ChannelPosts.FirstOrDefaultAsync(p => p.PostId == postId && p.ChannelId == channel.ChannelId, ct);
            // A dismiss may close reports of a post that retention already
            // removed; every other post action needs the post itself.
            var hasReports = await db.ChannelReports.AnyAsync(r => r.ChannelId == channel.ChannelId && r.PostId == postId, ct);
            if (post is null && !(action == Dismiss && hasReports))
                return Fail(404, "post_not_found", "Post not found.");
        }

        var now = DateTimeOffset.UtcNow;
        if (channel.DeletedAt is not null && action is (SuspendChannel or TerminateChannel or RestoreChannel))
            return Fail(409, "channel_deleted", "The channel is already deleted.");
        if (action == RestoreChannel && !channel.IsSuspended(now))
            return Fail(409, "not_suspended", "The channel is not suspended.");
        if (action == RemovePost && post!.DeletedAt is not null)
            return Fail(409, "already_removed", "The post is already removed.");

        // Which open reports this decision resolves (contract 4.6 Effects).
        var reports = db.ChannelReports.Where(r => r.ChannelId == channel.ChannelId && r.Status == StatusOpen);
        reports = action switch
        {
            Dismiss when request.PostId is { } p => reports.Where(r => r.PostId == p),
            Dismiss => reports.Where(r => r.PostId == null),
            RemovePost => reports.Where(r => r.PostId == request.PostId),
            SuspendChannel or TerminateChannel => reports, // the channel AND all its posts
            _ => reports.Where(r => false)                 // restore leaves reports untouched
        };

        // PostgreSQL keeps microseconds; truncate so createdAt in the 201
        // equals the stored value (it is the cursor of GET /admin/decisions).
        now = new DateTimeOffset(now.Ticks - now.Ticks % 10, TimeSpan.Zero);

        await using var tx = await db.Database.BeginTransactionAsync(ct);

        var decision = new ModerationDecision
        {
            ChannelId = channel.ChannelId,
            PostId = request.PostId,
            Action = action,
            Ground = ground,
            Rule = rule,
            LegalGround = legalGround,
            Explanation = explanation,
            OperatorAccountId = operatorAccountId,
            CreatedAt = now
        };

        switch (action)
        {
            case RemovePost:
                post!.DeletedAt = now;
                break;
            case SuspendChannel:
                channel.SuspendedUntil = now.AddDays(request.SuspendDays!.Value);
                decision.SuspendedUntil = channel.SuspendedUntil;
                break;
            case TerminateChannel:
                channel.DeletedAt = now;
                break;
            case RestoreChannel:
                channel.SuspendedUntil = null;
                break;
        }

        db.ModerationDecisions.Add(decision);
        await db.SaveChangesAsync(ct); // assigns decision.Id for the report rows

        var newStatus = action == Dismiss ? StatusDismissed : StatusActioned;
        decision.ReportCount = await reports.ExecuteUpdateAsync(s => s
            .SetProperty(r => r.Status, newStatus)
            .SetProperty(r => r.ResolvedAt, (DateTimeOffset?)now)
            .SetProperty(r => r.DecisionId, (long?)decision.Id), ct);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        // After the commit: clients must never see a tombstone / ChannelDeleted
        // for a change that could still roll back.
        if (action == RemovePost) await channels.BroadcastTombstoneAsync(post!, ct);
        if (action == TerminateChannel) await channels.BroadcastChannelDeletedAsync(channel.ChannelId);

        return new DecisionOutcome(decision, 201, null, null);
    }
}
