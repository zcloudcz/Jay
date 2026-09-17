// ---------------------------------------------------------------------------
// ChannelService.cs — Business logic for public one-way channels
// ---------------------------------------------------------------------------
// Everything ChannelEndpoints needs that is more than HTTP plumbing: who may do
// what, idempotent follow/publish, aggregated reaction/vote totals, the hub
// fan-out and the throttled push.
//
// ANONYMITY (hard requirement, plan §6): nothing built here for a response or
// a hub event may carry the DeviceId of a follower, reactor, voter, reporter or
// post author. The server knows those links (it needs them for delivery and
// "one reaction per device"), but only ever exposes totals plus the CALLER'S
// own reaction/vote. When adding a field to an anonymous object below, check it
// against that rule first.
//
// OWNERSHIP: owner rights come from Channel.OwnerAccountId — every device
// linked to that account is an owner, so the channel survives the loss of the
// creating device. ChannelAdmin rows are delegated admins only (publish, edit,
// delete posts); there is deliberately no "owner" row to keep in sync.
// ---------------------------------------------------------------------------

using System.Text.Json;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Hubs;
using CallType.Api.Models;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using Npgsql;

namespace CallType.Api.Services;

public enum ChannelRole { None, Admin, Owner }

public enum CreateChannelResult { Created, NoAccount, LimitReached }

/// <summary>Reaction and vote totals of one post plus the caller's own choice.</summary>
public record PostTotals(
    Dictionary<string, int> Reactions, string? MyReaction,
    Dictionary<string, int> Votes, int? MyVote);

/// <summary>Poll definition as stored (camelCase JSON) in ChannelPost.Body.</summary>
public record PollDefinition(string Question, List<string> Options, DateTimeOffset? ClosesAt);

public class ChannelService(
    AppDbContext db,
    IHubContext<MessengerHub> hub,
    PushNotificationService push,
    IOptions<ChannelsOptions> options,
    ILogger<ChannelService> logger)
{
    // Same six reactions WhatsApp offers. Written as escapes so the whitelist
    // does not depend on how an editor saves this file. The heart is stored
    // WITH the U+FE0F variation selector (the form keyboards produce).
    private const string Heart = "❤️";
    public static readonly IReadOnlyList<string> AllowedEmoji =
    [
        "\U0001F44D", // thumbs up
        Heart,
        "\U0001F602", // face with tears of joy
        "\U0001F62E", // face with open mouth
        "\U0001F622", // crying face
        "\U0001F64F"  // folded hands
    ];

    // A device may file this many reports per 24 h across all channels. Counted
    // from the ChannelReports table rather than an in-memory limiter so it
    // survives restarts and needs no extra rate-limit policy.
    public const int MaxReportsPerDay = 5;

    private static readonly JsonSerializerOptions PollJson = new(JsonSerializerDefaults.Web);

    private readonly ChannelsOptions _options = options.Value;

    // -----------------------------------------------------------------------
    // Pure helpers (unit tested without a database)
    // -----------------------------------------------------------------------

    /// <summary>API kind ("text"/"image"/"poll", lowercase) -> enum. Null = unknown.</summary>
    public static ChannelPostKind? ParseKind(string? kind) => kind switch
    {
        // An explicit switch, not Enum.TryParse: TryParse would also accept
        // "1" or "Image", and the wire contract is lowercase names only.
        "text" => ChannelPostKind.Text,
        "image" => ChannelPostKind.Image,
        "poll" => ChannelPostKind.Poll,
        _ => null
    };

    public static string KindToApi(ChannelPostKind kind) => kind.ToString().ToLowerInvariant();

    /// <summary>Returns the canonical whitelisted emoji, or null if not allowed (-> 422).</summary>
    public static string? NormalizeEmoji(string? emoji)
    {
        // Some clients send the heart without the variation selector.
        if (emoji == "❤") return Heart;
        return emoji is not null && AllowedEmoji.Contains(emoji) ? emoji : null;
    }

    /// <summary>
    /// Validates a poll definition and returns it re-serialized in canonical
    /// form. Re-serializing (instead of storing the client's text) guarantees
    /// every follower later parses exactly the shape the server validated —
    /// unknown properties are dropped, option strings are trimmed.
    /// </summary>
    public static bool TryNormalizePoll(string json, DateTimeOffset now, out string normalized, out string error)
    {
        normalized = "";
        PollDefinition? poll;
        try { poll = JsonSerializer.Deserialize<PollDefinition>(json, PollJson); }
        catch (JsonException) { poll = null; }

        if (poll is null || poll.Options is null)
        {
            error = "Poll body must be JSON { question, options, closesAt? }.";
            return false;
        }

        var question = poll.Question?.Trim() ?? "";
        var pollOptions = poll.Options.Select(o => o?.Trim() ?? "").ToList();

        if (question.Length is 0 or > 512) error = "Poll question must be 1-512 characters.";
        else if (pollOptions.Count is < 2 or > 10) error = "Poll must have 2-10 options.";
        else if (pollOptions.Any(o => o.Length is 0 or > 100)) error = "Poll options must be 1-100 characters.";
        else if (poll.ClosesAt is { } closes && closes <= now) error = "closesAt must be in the future.";
        else
        {
            normalized = JsonSerializer.Serialize(
                new PollDefinition(question, pollOptions, poll.ClosesAt?.ToUniversalTime()), PollJson);
            error = normalized.Length > 4096 ? "Poll is too long." : "";
            return error.Length == 0;
        }
        return false;
    }

    public static PollDefinition ParseStoredPoll(string body) =>
        JsonSerializer.Deserialize<PollDefinition>(body, PollJson)!;

    // -----------------------------------------------------------------------
    // Lookups and authorization
    // -----------------------------------------------------------------------

    /// <summary>Live channel by id; soft-deleted channels are "not found" for everybody.</summary>
    public Task<Channel?> FindAsync(Guid channelId, CancellationToken ct) =>
        db.Channels.FirstOrDefaultAsync(c => c.ChannelId == channelId && c.DeletedAt == null, ct);

    public Task<Channel?> FindByHandleAsync(string handle, CancellationToken ct) =>
        db.Channels.FirstOrDefaultAsync(c => c.Handle == handle && c.DeletedAt == null, ct);

    public async Task<ChannelRole> GetRoleAsync(Channel channel, Guid deviceId, CancellationToken ct)
    {
        if (await db.AccountDevices.AnyAsync(
                ad => ad.DeviceId == deviceId && ad.AccountId == channel.OwnerAccountId, ct))
            return ChannelRole.Owner;

        return await db.ChannelAdmins.AnyAsync(
            a => a.ChannelId == channel.ChannelId && a.DeviceId == deviceId, ct)
            ? ChannelRole.Admin
            : ChannelRole.None;
    }

    public Task<bool> IsFollowingAsync(Guid channelId, Guid deviceId, CancellationToken ct) =>
        db.ChannelFollowers.AnyAsync(f => f.ChannelId == channelId && f.DeviceId == deviceId, ct);

    // -----------------------------------------------------------------------
    // Create
    // -----------------------------------------------------------------------

    public async Task<(CreateChannelResult Result, Channel? Channel)> CreateAsync(
        Guid deviceId, string name, string description, CancellationToken ct)
    {
        // Owner decision (plan §7.4): only a device linked to a registered
        // account may create a channel. Following stays open to anonymous devices.
        var accountId = await db.AccountDevices
            .Where(ad => ad.DeviceId == deviceId)
            .OrderBy(ad => ad.LinkedAt)
            .Select(ad => (Guid?)ad.AccountId)
            .FirstOrDefaultAsync(ct);
        if (accountId is null) return (CreateChannelResult.NoAccount, null);

        // HandleGenerator does not guarantee uniqueness — the unique index does.
        // A collision is astronomically rare, so a couple of retries is plenty.
        for (var attempt = 0; ; attempt++)
        {
            await using var tx = await db.Database.BeginTransactionAsync(ct);

            // Serialize creates of ONE account so two parallel requests cannot
            // both pass the limit check below. Per-account key = no contention
            // between different owners. Released automatically at commit/rollback.
            var lockKey = $"channel-owner:{accountId}";
            await db.Database.ExecuteSqlInterpolatedAsync(
                $"SELECT pg_advisory_xact_lock(hashtext({lockKey}))", ct);

            // The option is called "PerDevice" for historical reasons; since
            // ownership moved to the account (plan §7.4) the limit is per account,
            // otherwise linking more devices would multiply the quota.
            var owned = await db.Channels.CountAsync(
                c => c.OwnerAccountId == accountId && c.DeletedAt == null, ct);
            if (owned >= _options.MaxOwnedPerDevice) return (CreateChannelResult.LimitReached, null);

            var channel = new Channel
            {
                ChannelId = Guid.NewGuid(),
                Handle = HandleGenerator.Generate(HandleGenerator.ChannelPrefix),
                Name = name,
                Description = description,
                OwnerDeviceId = deviceId,
                OwnerAccountId = accountId.Value,
                CreatedAt = DateTimeOffset.UtcNow
            };
            db.Channels.Add(channel);

            try
            {
                await db.SaveChangesAsync(ct);
                await tx.CommitAsync(ct);
                return (CreateChannelResult.Created, channel);
            }
            catch (DbUpdateException ex) when (IsUniqueViolation(ex) && attempt < 3)
            {
                // Handle collision: the PostgreSQL transaction is now aborted, so
                // roll back, forget the failed entity and retry from the top.
                await tx.RollbackAsync(ct);
                db.ChangeTracker.Clear();
            }
        }
    }

    private static bool IsUniqueViolation(DbUpdateException ex) =>
        ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation };

    // -----------------------------------------------------------------------
    // Follow / unfollow
    // -----------------------------------------------------------------------

    public async Task FollowAsync(Guid channelId, Guid deviceId, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var now = DateTimeOffset.UtcNow;

        // ON CONFLICT DO NOTHING makes the insert itself idempotent AND race
        // free: of two parallel follows exactly one reports 1 affected row, so
        // FollowerCount is bumped exactly once. "Check then insert" in EF would
        // need a retry on unique violation to achieve the same.
        var inserted = await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
             INSERT INTO "ChannelFollowers" ("ChannelId", "DeviceId", "FollowedAt")
             VALUES ({channelId}, {deviceId}, {now})
             ON CONFLICT DO NOTHING
             """, ct);

        if (inserted == 1)
            await db.Channels.Where(c => c.ChannelId == channelId)
                .ExecuteUpdateAsync(s => s.SetProperty(c => c.FollowerCount, c => c.FollowerCount + 1), ct);

        await tx.CommitAsync(ct);
    }

    public async Task UnfollowAsync(Guid channelId, Guid deviceId, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);

        // Rows affected tells us whether there was anything to unfollow, so a
        // repeated unfollow never drives the counter below the truth.
        var deleted = await db.ChannelFollowers
            .Where(f => f.ChannelId == channelId && f.DeviceId == deviceId)
            .ExecuteDeleteAsync(ct);

        if (deleted == 1)
            await db.Channels.Where(c => c.ChannelId == channelId)
                .ExecuteUpdateAsync(s => s.SetProperty(c => c.FollowerCount, c => c.FollowerCount - 1), ct);

        await tx.CommitAsync(ct);
    }

    // -----------------------------------------------------------------------
    // Posts
    // -----------------------------------------------------------------------

    /// <summary>
    /// Stores a post and fans it out. Returns Created=false when a post with
    /// this PostId already exists in the channel (client retry) — then nothing
    /// is stored or sent again. Returns null when the PostId belongs to a
    /// DIFFERENT channel (a real conflict, not a retry).
    /// </summary>
    public async Task<(bool Created, ChannelPost Post)?> PublishAsync(
        Channel channel, Guid authorDeviceId, Guid postId, ChannelPostKind kind,
        string body, string? attachmentBlobPath, CancellationToken ct)
    {
        var existing = await db.ChannelPosts.AsNoTracking().FirstOrDefaultAsync(p => p.PostId == postId, ct);
        if (existing is null)
        {
            var now = DateTimeOffset.UtcNow;
            var post = new ChannelPost
            {
                PostId = postId,
                ChannelId = channel.ChannelId,
                AuthorDeviceId = authorDeviceId,
                Kind = kind,
                Body = body,
                AttachmentBlobPath = attachmentBlobPath,
                // PostgreSQL keeps microseconds, .NET has 100 ns ticks. Truncate
                // up front so the createdAt we return/broadcast now is exactly the
                // value stored — clients use it as the before/after paging cursor.
                CreatedAt = new DateTimeOffset(now.Ticks - now.Ticks % 10, TimeSpan.Zero)
            };
            db.ChannelPosts.Add(post);

            try
            {
                await db.SaveChangesAsync(ct);
                await BroadcastPostAsync(post);
                NotifyOfflineFollowers(channel.ChannelId);
                return (true, post);
            }
            catch (DbUpdateException ex) when (IsUniqueViolation(ex))
            {
                // Two parallel retries of the same PostId: the other one won.
                // Fall through and answer like a normal duplicate.
                db.ChangeTracker.Clear();
                existing = await db.ChannelPosts.AsNoTracking().FirstAsync(p => p.PostId == postId, ct);
            }
        }

        return existing.ChannelId == channel.ChannelId ? (false, existing) : null;
    }

    /// <summary>Soft-deletes a post and sends the tombstone. False = no such live post.</summary>
    public async Task<bool> DeletePostAsync(Guid channelId, Guid postId, CancellationToken ct)
    {
        var post = await db.ChannelPosts.FirstOrDefaultAsync(
            p => p.PostId == postId && p.ChannelId == channelId && p.DeletedAt == null, ct);
        if (post is null) return false;

        post.DeletedAt = DateTimeOffset.UtcNow;
        await db.SaveChangesAsync(ct);
        await BroadcastPostAsync(post);
        return true;
    }

    public async Task DeleteChannelAsync(Channel channel, CancellationToken ct)
    {
        channel.DeletedAt = DateTimeOffset.UtcNow;
        await db.SaveChangesAsync(ct);
        await hub.Clients.Group(MessengerHub.ChannelGroup(channel.ChannelId))
            .SendAsync("ChannelDeleted", new { channelId = channel.ChannelId }, CancellationToken.None);
    }

    /// <summary>
    /// The wire shape of a post, shared by the REST responses and the hub event
    /// so clients parse one format. A deleted post is a tombstone: content is
    /// blanked so a soft delete really removes the text from every client.
    /// NOTE: AuthorDeviceId is intentionally absent (anonymity of admins too).
    /// </summary>
    public static object PostEvent(ChannelPost post)
    {
        var deleted = post.DeletedAt is not null;
        return new
        {
            channelId = post.ChannelId,
            postId = post.PostId,
            kind = KindToApi(post.Kind),
            body = deleted ? "" : post.Body,
            attachmentBlobPath = deleted ? null : post.AttachmentBlobPath,
            createdAt = post.CreatedAt,
            deleted
        };
    }

    // CancellationToken.None on purpose: the row is already committed, so a
    // client that hung up right after must not cancel the fan-out to others.
    private Task BroadcastPostAsync(ChannelPost post) =>
        hub.Clients.Group(MessengerHub.ChannelGroup(post.ChannelId))
            .SendAsync("ReceiveChannelPost", PostEvent(post), CancellationToken.None);

    private void NotifyOfflineFollowers(Guid channelId)
    {
        // Fire-and-forget: a channel can have thousands of followers and the
        // admin's POST must not wait for that many FCM calls. The push service
        // opens its own DI scope and swallows/logs its own failures.
        _ = push.SendChannelPostPushAsync(
            channelId, TimeSpan.FromMinutes(_options.PushThrottleMinutes), MessengerHub.IsOnline);
    }

    /// <summary>
    /// Totals for a page of posts in a constant number of grouped queries
    /// (4, regardless of page size) — never one query per post.
    /// </summary>
    public async Task<Dictionary<Guid, PostTotals>> TotalsAsync(
        IReadOnlyCollection<Guid> postIds, Guid deviceId, CancellationToken ct)
    {
        var reactions = await db.ChannelReactions.Where(r => postIds.Contains(r.PostId))
            .GroupBy(r => new { r.PostId, r.Emoji })
            .Select(g => new { g.Key.PostId, g.Key.Emoji, Count = g.Count() })
            .ToListAsync(ct);
        var votes = await db.ChannelPollVotes.Where(v => postIds.Contains(v.PostId))
            .GroupBy(v => new { v.PostId, v.OptionIndex })
            .Select(g => new { g.Key.PostId, g.Key.OptionIndex, Count = g.Count() })
            .ToListAsync(ct);
        var myReactions = await db.ChannelReactions
            .Where(r => postIds.Contains(r.PostId) && r.DeviceId == deviceId)
            .ToDictionaryAsync(r => r.PostId, r => r.Emoji, ct);
        var myVotes = await db.ChannelPollVotes
            .Where(v => postIds.Contains(v.PostId) && v.DeviceId == deviceId)
            .ToDictionaryAsync(v => v.PostId, v => v.OptionIndex, ct);

        return postIds.ToDictionary(id => id, id => new PostTotals(
            reactions.Where(r => r.PostId == id).ToDictionary(r => r.Emoji, r => r.Count),
            myReactions.GetValueOrDefault(id),
            // JSON object keys are strings, so the option index is keyed as "0", "1", ...
            votes.Where(v => v.PostId == id).ToDictionary(v => v.OptionIndex.ToString(), v => v.Count),
            myVotes.TryGetValue(id, out var mine) ? mine : null));
    }

    // -----------------------------------------------------------------------
    // Reactions, votes, reports
    // -----------------------------------------------------------------------

    public Task SetReactionAsync(Guid postId, Guid deviceId, string emoji, CancellationToken ct)
    {
        // Upsert in one statement: the (PostId, DeviceId) primary key is what
        // enforces "one reaction per device", and a double-tap race cannot fail.
        var now = DateTimeOffset.UtcNow;
        return db.Database.ExecuteSqlInterpolatedAsync(
            $"""
             INSERT INTO "ChannelReactions" ("PostId", "DeviceId", "Emoji", "CreatedAt")
             VALUES ({postId}, {deviceId}, {emoji}, {now})
             ON CONFLICT ("PostId", "DeviceId") DO UPDATE SET "Emoji" = EXCLUDED."Emoji"
             """, ct);
    }

    public Task SetVoteAsync(Guid postId, Guid deviceId, int optionIndex, CancellationToken ct) =>
        db.Database.ExecuteSqlInterpolatedAsync(
            $"""
             INSERT INTO "ChannelPollVotes" ("PostId", "DeviceId", "OptionIndex")
             VALUES ({postId}, {deviceId}, {optionIndex})
             ON CONFLICT ("PostId", "DeviceId") DO UPDATE SET "OptionIndex" = EXCLUDED."OptionIndex"
             """, ct);

    /// <summary>Stores a report. False = the device used up its daily report budget (429).</summary>
    public async Task<bool> ReportAsync(
        Guid channelId, Guid? postId, Guid reporterDeviceId, string reason, CancellationToken ct)
    {
        var since = DateTimeOffset.UtcNow.AddDays(-1);
        var recent = await db.ChannelReports.CountAsync(
            r => r.ReporterDeviceId == reporterDeviceId && r.CreatedAt > since, ct);
        if (recent >= MaxReportsPerDay) return false;

        var report = new ChannelReport
        {
            ChannelId = channelId,
            PostId = postId,
            ReporterDeviceId = reporterDeviceId,
            Reason = reason,
            CreatedAt = DateTimeOffset.UtcNow
        };
        db.ChannelReports.Add(report);
        await db.SaveChangesAsync(ct);

        // There is NO e-mail infrastructure in this API (no SMTP client, no mail
        // provider) and adding one just for this was ruled out. The operator is
        // therefore notified through a structured Warning log — alert on
        // "Channel report" in App Service logs. ReportNotifyEmail is logged so
        // the alert rule can route it; wire real mail here once a sender exists.
        // The reporter's id and free-text reason stay in the DB row only.
        logger.LogWarning(
            "Channel report {ReportId} filed: channel {ChannelId}, post {PostId}, notify {NotifyEmail}",
            report.Id, channelId, postId, _options.ReportNotifyEmail);
        return true;
    }
}
