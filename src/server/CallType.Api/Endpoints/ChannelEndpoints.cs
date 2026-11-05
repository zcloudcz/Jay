// ---------------------------------------------------------------------------
// ChannelEndpoints.cs — Public one-way channels (WhatsApp Channels style)
// ---------------------------------------------------------------------------
// Contract: docs/superpowers/plans/2026-09-16-channels.md §2, with §7 taking
// precedence (no video, image <= Channels:MaxImageBytes, only a device linked
// to a registered account may create a channel, report endpoint, no catalogue).
//
// This file is HTTP plumbing only — validation of the request shape, mapping
// of outcomes to status codes and building response JSON. Rules that matter
// (roles, idempotence, totals, fan-out, push) live in ChannelService.
//
// Identity ALWAYS comes from the JWT (AccountEndpoints.CallerDeviceId), never
// from the URL or body (K01). The only device id accepted in a URL is the
// TARGET of owner-only admin management.
//
// ANONYMITY: responses carry follower COUNTS, reaction/vote TOTALS and the
// caller's own reaction/vote — never anyone's DeviceId. The one exception is
// GET /channels/{id}/admins, which shows delegated admins to the owner who
// appointed them. ChannelEndpointsTests scans every response for leaks.
//
// Status codes: 403 not a follower / not an admin, 404 unknown or deleted
// channel/post, 409 owned-channel limit (and closed poll), 413 image too
// large, 422 emoji not whitelisted / bad poll option index.
//
// MODERATION (docs/superpowers/specs/2026-11-05-channel-moderation-contract.md
// section 3): roles owner/admin/publisher, 403 channel_suspended while an
// operator suspension runs, report categories + receipt, the reporter's
// "Reports I filed" list and the owner's statements of reasons.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace CallType.Api.Endpoints;

public static partial class ChannelEndpoints
{
    // Canonical AttachmentBlobPath = "channel-media/{channelId}/{name}", i.e.
    // WITH the container prefix, the same convention Backup.BlobPath uses.
    // ChannelPostCleanupService accepts both forms; the API only ever emits and
    // accepts this one so clients can compare paths as plain strings.
    internal const string ContainerName = ChannelPostCleanupService.ContainerName;

    // Whitelist of image types -> file extension. SVG is deliberately missing:
    // it can carry script, and these files are served back unencrypted.
    internal static readonly Dictionary<string, string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["image/jpeg"] = "jpg", ["image/png"] = "png", ["image/webp"] = "webp", ["image/gif"] = "gif"
    };

    // Server-generated names only ("{guid:N}.{ext}") — a strict pattern means a
    // name from the URL can never traverse out of the channel's blob folder.
    [GeneratedRegex("^[0-9a-f]{32}\\.(jpg|png|webp|gif)$")]
    internal static partial Regex AttachmentName();

    public static WebApplication MapChannelEndpoints(this WebApplication app)
    {
        var group = app.MapGroup("/channels").RequireAuthorization().RequireRateLimiting("api");

        group.MapPost("", CreateChannel);
        // Literal "mine" outranks the {idOrHandle} parameter in route precedence.
        group.MapGet("/mine", ListMine);
        group.MapGet("/reports/mine", MyReports);
        group.MapGet("/{idOrHandle}", GetChannel);
        group.MapPatch("/{id:guid}", UpdateChannel);
        group.MapDelete("/{id:guid}", DeleteChannel);

        group.MapGet("/{id:guid}/admins", ListAdmins);
        group.MapPut("/{id:guid}/admins/{deviceId:guid}", AddAdmin);
        group.MapDelete("/{id:guid}/admins/{deviceId:guid}", RemoveAdmin);

        group.MapPost("/{id:guid}/follow", Follow);
        group.MapDelete("/{id:guid}/follow", Unfollow);

        group.MapPost("/{id:guid}/posts", CreatePost);
        group.MapGet("/{id:guid}/posts", ListPosts);
        group.MapDelete("/{id:guid}/posts/{postId:guid}", DeletePost);

        group.MapPut("/{id:guid}/posts/{postId:guid}/reaction", SetReaction);
        group.MapDelete("/{id:guid}/posts/{postId:guid}/reaction", RemoveReaction);
        group.MapPut("/{id:guid}/posts/{postId:guid}/vote", Vote);

        group.MapPost("/{id:guid}/report", Report);
        group.MapGet("/{id:guid}/moderation", ModerationStatements);

        // Multipart from non-browser clients carries no antiforgery token
        // (same reason as the backup upload).
        group.MapPost("/{id:guid}/attachments", UploadAttachment).DisableAntiforgery();
        group.MapGet("/{id:guid}/attachments/{name}", DownloadAttachment);

        return app;
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------

    private static IResult Error(int status, string error, string? code = null) =>
        Results.Json(new { error, code }, statusCode: status);

    private static IResult ChannelNotFound() => Error(StatusCodes.Status404NotFound, "Channel not found.");

    private static IResult Suspended() =>
        Error(403, "This channel is suspended by the operator.", "channel_suspended");

    private static string? RoleToApi(ChannelRole role) => role switch
    {
        ChannelRole.Owner => "owner",
        ChannelRole.Admin => "admin",
        ChannelRole.Publisher => ChannelService.PublisherRole,
        _ => null
    };

    /// <summary>Public profile. OwnerDeviceId / OwnerAccountId are intentionally not part of it.</summary>
    private static object ChannelDto(Channel c, bool isFollowing, ChannelRole role, int unreadCount = 0)
    {
        // The profile stays visible while suspended (it carries the status),
        // so followers learn why the feed is gone instead of seeing an error.
        var suspended = c.IsSuspended(DateTimeOffset.UtcNow);
        return new
        {
            channelId = c.ChannelId,
            handle = c.Handle,
            name = c.Name,
            description = c.Description,
            followerCount = c.FollowerCount,
            createdAt = c.CreatedAt,
            isFollowing,
            role = RoleToApi(role),
            unreadCount,
            status = suspended ? "suspended" : "active",
            suspendedUntil = suspended ? c.SuspendedUntil : null
        };
    }

    private static object PostDto(ChannelPost post, PostTotals totals, bool byBot)
    {
        var deleted = post.DeletedAt is not null;
        return new
        {
            channelId = post.ChannelId,
            postId = post.PostId,
            kind = ChannelService.KindToApi(post.Kind),
            // Same tombstone rule as the hub event (ChannelService.PostEvent).
            body = deleted ? "" : post.Body,
            attachmentBlobPath = deleted ? null : post.AttachmentBlobPath,
            createdAt = post.CreatedAt,
            deleted,
            reactions = totals.Reactions,
            myReaction = totals.MyReaction,
            votes = totals.Votes,
            myVote = totals.MyVote,
            byBot
        };
    }

    private static readonly PostTotals NoTotals = new([], null, [], null);

    /// <summary>Validates name/description. Returns an error message or null.</summary>
    private static string? ValidateProfile(string? name, string? description)
    {
        if (name is not null && name.Trim().Length is 0 or > 64) return "Name must be 1-64 characters.";
        if (description is not null && description.Trim().Length > 512) return "Description must be at most 512 characters.";
        return null;
    }

    // -----------------------------------------------------------------------
    // POST /channels — create (only a device linked to a registered account)
    // -----------------------------------------------------------------------
    private static async Task<IResult> CreateChannel(
        CreateChannelRequest request, ClaimsPrincipal user, ChannelService channels, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();

        if (request.Name is null) return Error(400, "Name is required.");
        if (ValidateProfile(request.Name, request.Description) is { } invalid) return Error(400, invalid);

        var (result, channel) = await channels.CreateAsync(
            me, request.Name.Trim(), request.Description?.Trim() ?? "", ct);

        return result switch
        {
            CreateChannelResult.NoAccount => Error(403,
                "Only a device linked to a registered account can create a channel.", "account_required"),
            CreateChannelResult.LimitReached => Error(409,
                "Owned channel limit reached.", "channel_limit_reached"),
            _ => Results.Created($"/channels/{channel!.ChannelId}", ChannelDto(channel, false, ChannelRole.Owner))
        };
    }

    // -----------------------------------------------------------------------
    // GET /channels/mine — followed + owned + administered, with unread counts
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListMine(ClaimsPrincipal user, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();

        // One SQL statement for all followed channels; the unread count is a
        // correlated sub-select, not a query per channel. A fresh follower starts
        // at 0 unread (baseline = FollowedAt) rather than "whole history unread".
        var followed = await db.ChannelFollowers.AsNoTracking()
            .Where(f => f.DeviceId == me && f.Channel.DeletedAt == null)
            .Select(f => new
            {
                f.Channel,
                Unread = f.Channel.Posts.Count(p =>
                    p.DeletedAt == null && p.CreatedAt > (f.LastSeenPostAt ?? f.FollowedAt))
            })
            .ToListAsync(ct);

        var managed = await db.Channels.AsNoTracking()
            .Where(c => c.DeletedAt == null && (
                c.Admins.Any(a => a.DeviceId == me) ||
                db.AccountDevices.Any(ad => ad.DeviceId == me && ad.AccountId == c.OwnerAccountId)))
            .Select(c => new
            {
                Channel = c,
                IsOwner = db.AccountDevices.Any(ad => ad.DeviceId == me && ad.AccountId == c.OwnerAccountId),
                AdminRole = c.Admins.Where(a => a.DeviceId == me).Select(a => a.Role).FirstOrDefault()
            })
            .ToListAsync(ct);

        var roles = managed.ToDictionary(
            m => m.Channel.ChannelId,
            m => m.IsOwner ? ChannelRole.Owner : ChannelService.ParseAdminRole(m.AdminRole));
        var followedIds = followed.Select(f => f.Channel.ChannelId).ToHashSet();

        var result = followed
            .Select(f => ChannelDto(f.Channel, true,
                roles.GetValueOrDefault(f.Channel.ChannelId, ChannelRole.None), f.Unread))
            // Managed but not followed: no unread badge — the admin wrote those posts.
            .Concat(managed.Where(m => !followedIds.Contains(m.Channel.ChannelId))
                .Select(m => ChannelDto(m.Channel, false, roles[m.Channel.ChannelId])));

        return Results.Ok(result);
    }

    // -----------------------------------------------------------------------
    // GET /channels/{idOrHandle} — public profile (discovery is link/QR/handle only)
    // -----------------------------------------------------------------------
    private static async Task<IResult> GetChannel(
        string idOrHandle, ClaimsPrincipal user, ChannelService channels, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();

        // Handles are generated uppercase; accept what a user typed by hand.
        var channel = Guid.TryParse(idOrHandle, out var id)
            ? await channels.FindAsync(id, ct)
            : await channels.FindByHandleAsync(idOrHandle.Trim().ToUpperInvariant(), ct);
        if (channel is null) return ChannelNotFound();

        return Results.Ok(ChannelDto(channel,
            await channels.IsFollowingAsync(channel.ChannelId, me, ct),
            await channels.GetRoleAsync(channel, me, ct)));
    }

    // -----------------------------------------------------------------------
    // PATCH /channels/{id} — name/description (owner or admin)
    // -----------------------------------------------------------------------
    private static async Task<IResult> UpdateChannel(
        Guid id, UpdateChannelRequest request, ClaimsPrincipal user,
        ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();

        // Publishers only publish (design D9): the profile is owner/admin business.
        var role = await channels.GetRoleAsync(channel, me, ct);
        if (role is not (ChannelRole.Owner or ChannelRole.Admin)) return Results.Forbid();
        if (ValidateProfile(request.Name, request.Description) is { } invalid) return Error(400, invalid);

        // PATCH semantics: a property that is absent (null) stays unchanged.
        if (request.Name is not null) channel.Name = request.Name.Trim();
        if (request.Description is not null) channel.Description = request.Description.Trim();
        await db.SaveChangesAsync(ct);

        return Results.Ok(ChannelDto(channel, await channels.IsFollowingAsync(id, me, ct), role));
    }

    // -----------------------------------------------------------------------
    // DELETE /channels/{id} — soft delete (owner); followers get ChannelDeleted
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeleteChannel(
        Guid id, ClaimsPrincipal user, ChannelService channels, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        if (await channels.GetRoleAsync(channel, me, ct) != ChannelRole.Owner) return Results.Forbid();

        await channels.DeleteChannelAsync(channel, ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // Admin management (owner only)
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListAdmins(
        Guid id, ClaimsPrincipal user, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        if (await channels.GetRoleAsync(channel, me, ct) != ChannelRole.Owner) return Results.Forbid();

        // The only place a device id leaves the channel API: the owner sees the
        // admins they appointed themselves (needed to be able to remove them).
        // Handle / display name / bot flag are the device's public metadata
        // (same as a contact lookup) so the owner can tell members apart.
        var admins = await db.ChannelAdmins.AsNoTracking()
            .Where(a => a.ChannelId == id)
            .OrderBy(a => a.AddedAt)
            .Join(db.Devices, a => a.DeviceId, d => d.DeviceId, (a, d) => new
            {
                deviceId = a.DeviceId,
                addedAt = a.AddedAt,
                role = a.Role,
                isBot = d.IsBot,
                handle = d.UserHandle,
                displayName = d.DisplayName
            })
            .ToListAsync(ct);
        return Results.Ok(admins);
    }

    private static async Task<IResult> AddAdmin(
        Guid id, Guid deviceId, HttpRequest http, ClaimsPrincipal user,
        ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        if (await channels.GetRoleAsync(channel, me, ct) != ChannelRole.Owner) return Results.Forbid();

        // The body is optional (old clients send none = "admin"), so it is
        // read by hand: a bound body parameter would 415 a body-less PUT.
        var role = ChannelService.AdminRole;
        if (http.ContentLength is > 0 || http.Headers.TransferEncoding.Count > 0)
        {
            AddAdminRequest? request;
            try { request = await http.ReadFromJsonAsync<AddAdminRequest>(ct); }
            catch (Exception ex) when (ex is JsonException or InvalidOperationException)
            {
                return Error(400, "Body must be JSON {\"role\": \"admin\"|\"publisher\"}.", "invalid_role");
            }
            if (request?.Role is { } requested) role = requested;
        }
        if (role is not (ChannelService.AdminRole or ChannelService.PublisherRole))
            return Error(400, "role must be admin or publisher.", "invalid_role");

        if (!await db.Devices.AnyAsync(d => d.DeviceId == deviceId, ct))
            return Error(404, "Device not found.");

        // Idempotent PUT: the same role again changes nothing; another role
        // replaces the old one (promote a publisher to admin and back).
        var existing = await db.ChannelAdmins.FirstOrDefaultAsync(a => a.ChannelId == id && a.DeviceId == deviceId, ct);
        if (existing is null)
        {
            db.ChannelAdmins.Add(new ChannelAdmin
            {
                ChannelId = id, DeviceId = deviceId, Role = role, AddedAt = DateTimeOffset.UtcNow
            });
        }
        else
        {
            existing.Role = role;
        }
        await db.SaveChangesAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveAdmin(
        Guid id, Guid deviceId, ClaimsPrincipal user, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        if (await channels.GetRoleAsync(channel, me, ct) != ChannelRole.Owner) return Results.Forbid();

        await db.ChannelAdmins.Where(a => a.ChannelId == id && a.DeviceId == deviceId).ExecuteDeleteAsync(ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // Follow / unfollow — anyone, idempotent, 204
    // -----------------------------------------------------------------------
    private static async Task<IResult> Follow(
        Guid id, ClaimsPrincipal user, ChannelService channels, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        // No new audience while suspended (design D8). Unfollow stays allowed.
        if (channel.IsSuspended(DateTimeOffset.UtcNow)) return Suspended();

        await channels.FollowAsync(id, me, ct);
        return Results.NoContent();
    }

    private static async Task<IResult> Unfollow(
        Guid id, ClaimsPrincipal user, ChannelService channels, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is null) return ChannelNotFound();

        await channels.UnfollowAsync(id, me, ct);
        return Results.NoContent();
    }

    // -----------------------------------------------------------------------
    // POST /channels/{id}/posts - publish (owner/admin/publisher), idempotent on postId
    // -----------------------------------------------------------------------
    private static async Task<IResult> CreatePost(
        Guid id, CreatePostRequest request, ClaimsPrincipal user,
        ChannelService channels, BlobServiceClient blobService, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        if (await channels.GetRoleAsync(channel, me, ct) == ChannelRole.None) return Results.Forbid();
        // Nobody publishes into a suspended channel, the owner included:
        // that is the point of the suspension (contract 3).
        if (channel.IsSuspended(DateTimeOffset.UtcNow)) return Suspended();

        if (request.PostId == Guid.Empty) return Error(400, "postId (client-generated GUID) is required.");
        if (ChannelService.ParseKind(request.Kind) is not { } kind)
            return Error(400, "kind must be one of: text, image, poll.");

        // "body" is a string on the wire. For polls a client may also send the
        // definition as a JSON object instead of a string containing JSON —
        // both mean the same thing, so accept both rather than fail on a detail.
        var body = request.Body.ValueKind switch
        {
            JsonValueKind.String => request.Body.GetString()!,
            JsonValueKind.Object when kind == ChannelPostKind.Poll => request.Body.GetRawText(),
            JsonValueKind.Undefined or JsonValueKind.Null => "",
            _ => null
        };
        if (body is null || body.Length > 4096) return Error(400, "body must be a string of at most 4096 characters.");

        if (kind != ChannelPostKind.Image && request.AttachmentBlobPath is not null)
            return Error(400, "Only image posts can have an attachment.");

        switch (kind)
        {
            case ChannelPostKind.Text when string.IsNullOrWhiteSpace(body):
                return Error(400, "Text post must not be empty.");

            case ChannelPostKind.Poll:
                if (!ChannelService.TryNormalizePoll(body, DateTimeOffset.UtcNow, out body, out var pollError))
                    return Error(400, pollError);
                break;

            case ChannelPostKind.Image:
                // Must be a file uploaded to THIS channel via POST attachments —
                // otherwise a post could point at another channel's (or any) blob.
                var prefix = $"{ContainerName}/{id}/";
                var path = request.AttachmentBlobPath ?? "";
                if (!path.StartsWith(prefix, StringComparison.Ordinal) || !AttachmentName().IsMatch(path[prefix.Length..]))
                    return Error(400, "attachmentBlobPath must be a blobPath returned by POST /channels/{id}/attachments.");
                var blob = blobService.GetBlobContainerClient(ContainerName).GetBlobClient(path[(ContainerName.Length + 1)..]);
                if (!await blob.ExistsAsync(ct)) return Error(400, "Attachment does not exist.");
                break;
        }

        var (status, post, byBot) = await channels.PublishAsync(
            channel, me, request.PostId, kind, body, request.AttachmentBlobPath, ct);
        if (status == PublishStatus.PostIdConflict)
            return Error(409, "postId is already used in another channel.", "post_id_conflict");
        if (status == PublishStatus.BotLimitReached)
            return Error(429, "This bot reached its daily post limit for this channel.", "bot_post_limit");

        // A retry of an already stored postId answers 200 with the stored post
        // (not the retried payload) and triggers no second hub event or push.
        var dto = PostDto(post!, NoTotals, byBot);
        return status == PublishStatus.Created
            ? Results.Created($"/channels/{id}/posts/{post!.PostId}", dto)
            : Results.Ok(dto);
    }

    // -----------------------------------------------------------------------
    // GET /channels/{id}/posts?before=&after=&limit= — feed (follower or admin)
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListPosts(
        Guid id, DateTimeOffset? before, DateTimeOffset? after, int? limit,
        ClaimsPrincipal user, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();

        var isFollower = await channels.IsFollowingAsync(id, me, ct);
        var role = await channels.GetRoleAsync(channel, me, ct);
        if (!isFollower && role == ChannelRole.None)
            return Results.Forbid();
        // Suspended: hidden from followers, but the channel's own team still
        // reads it (they need to see what the statement of reasons is about).
        if (role == ChannelRole.None && channel.IsSuspended(DateTimeOffset.UtcNow)) return Suspended();

        var take = Math.Clamp(limit ?? 50, 1, 100);

        // Soft-deleted posts stay in the feed as tombstones (deleted=true, empty
        // content) so a client that was offline during the delete still learns
        // about it when it refreshes that page.
        var query = db.ChannelPosts.AsNoTracking().Where(p => p.ChannelId == id);
        if (before is { } b) query = query.Where(p => p.CreatedAt < b.ToUniversalTime());
        if (after is { } a) query = query.Where(p => p.CreatedAt > a.ToUniversalTime());

        // Catch-up (after only): take the OLDEST posts after the cursor so a
        // client that missed more than one page can walk forward without a gap.
        // The response itself is always ordered newest first.
        var posts = after is not null && before is null
            ? (await query.OrderBy(p => p.CreatedAt).Take(take).ToListAsync(ct)).AsEnumerable().Reverse().ToList()
            : await query.OrderByDescending(p => p.CreatedAt).Take(take).ToListAsync(ct);

        var totals = await channels.TotalsAsync(posts.Select(p => p.PostId).ToList(), me, ct);

        // Reading the feed is what "seen" means — there is no separate
        // mark-as-read call. Only ever moves forward, so paging back through
        // history cannot resurrect the unread badge.
        if (isFollower && posts.Count > 0)
        {
            var newest = posts[0].CreatedAt;
            await db.ChannelFollowers
                .Where(f => f.ChannelId == id && f.DeviceId == me &&
                            (f.LastSeenPostAt == null || f.LastSeenPostAt < newest))
                .ExecuteUpdateAsync(s => s.SetProperty(f => f.LastSeenPostAt, (DateTimeOffset?)newest), ct);
        }

        var bots = await channels.BotAuthorsAsync(posts.Select(p => p.AuthorDeviceId), ct);
        return Results.Ok(posts.Select(p => PostDto(p, totals[p.PostId], bots.Contains(p.AuthorDeviceId))));
    }

    // -----------------------------------------------------------------------
    // DELETE /channels/{id}/posts/{postId} - soft delete (owner/admin, publisher
    // own posts only) + tombstone
    // -----------------------------------------------------------------------
    private static async Task<IResult> DeletePost(
        Guid id, Guid postId, ClaimsPrincipal user, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        var role = await channels.GetRoleAsync(channel, me, ct);
        if (role == ChannelRole.None) return Results.Forbid();

        // A publisher (e.g. a newsletter bot) may retract what it wrote, never
        // someone else's post. Unknown post falls through to the 404 below.
        if (role == ChannelRole.Publisher &&
            await db.ChannelPosts.AnyAsync(p => p.PostId == postId && p.ChannelId == id && p.AuthorDeviceId != me, ct))
            return Results.Forbid();

        return await channels.DeletePostAsync(id, postId, ct)
            ? Results.NoContent()
            : Error(404, "Post not found.");
    }

    // -----------------------------------------------------------------------
    // Reactions and votes — followers only, one per device, totals in response
    // -----------------------------------------------------------------------

    /// <summary>
    /// Common gate for reaction/vote: live channel, caller follows it, live post
    /// of that channel. Returns the post or the error result to send.
    /// </summary>
    private static async Task<(ChannelPost? Post, IResult? Error)> FollowerPostAsync(
        Guid id, Guid postId, Guid me, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (await channels.FindAsync(id, ct) is not { } channel) return (null, ChannelNotFound());
        if (!await channels.IsFollowingAsync(id, me, ct)) return (null, Results.Forbid());
        if (channel.IsSuspended(DateTimeOffset.UtcNow)) return (null, Suspended());

        var post = await db.ChannelPosts.AsNoTracking().FirstOrDefaultAsync(
            p => p.PostId == postId && p.ChannelId == id && p.DeletedAt == null, ct);
        return post is null ? (null, Error(404, "Post not found.")) : (post, null);
    }

    /// <summary>Fresh totals of one post so the client can redraw without refetching the feed.</summary>
    private static async Task<IResult> TotalsResult(Guid postId, Guid me, ChannelService channels, CancellationToken ct)
    {
        var totals = (await channels.TotalsAsync([postId], me, ct))[postId];
        return Results.Ok(new
        {
            postId,
            reactions = totals.Reactions,
            myReaction = totals.MyReaction,
            votes = totals.Votes,
            myVote = totals.MyVote
        });
    }

    private static async Task<IResult> SetReaction(
        Guid id, Guid postId, ReactionRequest request, ClaimsPrincipal user,
        ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        var (post, error) = await FollowerPostAsync(id, postId, me, channels, db, ct);
        if (post is null) return error!;

        if (ChannelService.NormalizeEmoji(request.Emoji) is not { } emoji)
            return Error(422, "Emoji is not allowed.", "emoji_not_allowed");

        await channels.SetReactionAsync(postId, me, emoji, ct);
        return await TotalsResult(postId, me, channels, ct);
    }

    private static async Task<IResult> RemoveReaction(
        Guid id, Guid postId, ClaimsPrincipal user, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        var (post, error) = await FollowerPostAsync(id, postId, me, channels, db, ct);
        if (post is null) return error!;

        await db.ChannelReactions.Where(r => r.PostId == postId && r.DeviceId == me).ExecuteDeleteAsync(ct);
        return await TotalsResult(postId, me, channels, ct);
    }

    private static async Task<IResult> Vote(
        Guid id, Guid postId, VoteRequest request, ClaimsPrincipal user,
        ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        var (post, error) = await FollowerPostAsync(id, postId, me, channels, db, ct);
        if (post is null) return error!;

        if (post.Kind != ChannelPostKind.Poll) return Error(422, "Post is not a poll.", "not_a_poll");

        var poll = ChannelService.ParseStoredPoll(post.Body);
        if (request.OptionIndex is not { } index || index < 0 || index >= poll.Options.Count)
            return Error(422, "optionIndex is out of range.", "invalid_option_index");

        // Changing a vote is allowed until the poll closes; afterwards the
        // result is final, so neither a new nor a changed vote is accepted.
        if (poll.ClosesAt is { } closes && closes <= DateTimeOffset.UtcNow)
            return Error(409, "Poll is closed.", "poll_closed");

        await channels.SetVoteAsync(postId, me, index, ct);
        return await TotalsResult(postId, me, channels, ct);
    }

    // -----------------------------------------------------------------------
    // POST /channels/{id}/report - abuse report (follower), 200 with a receipt
    // -----------------------------------------------------------------------
    private static async Task<IResult> Report(
        Guid id, ReportRequest request, ClaimsPrincipal user,
        ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is null) return ChannelNotFound();
        if (!await channels.IsFollowingAsync(id, me, ct)) return Results.Forbid();

        var reason = request.Reason?.Trim() ?? "";
        if (reason.Length is 0 or > 512) return Error(400, "reason must be 1-512 characters.");

        // Old clients send no category: they keep working as a "terms" report.
        var category = request.Category?.Trim().ToLowerInvariant() ?? "terms";
        if (category is not ("illegal" or "terms" or "spam"))
            return Error(400, "category must be illegal, terms or spam.", "invalid_category");

        var contactEmail = string.IsNullOrWhiteSpace(request.ContactEmail) ? null : request.ContactEmail.Trim();
        if (contactEmail is not null && (contactEmail.Length > 254 || !contactEmail.Contains('@')))
            return Error(400, "contactEmail must be an e-mail address of at most 254 characters.", "invalid_contact");

        // DSA Art. 16(2)(d): a notice of illegal content carries the notifier's
        // statement that it is made in good faith.
        var goodFaith = request.GoodFaith ?? false;
        if (category == "illegal" && !goodFaith)
            return Error(400, "An illegal-content report requires the good-faith confirmation.", "good_faith_required");

        // A deleted post may still be reported (the admin may have removed it
        // to hide evidence) — it only has to belong to this channel.
        if (request.PostId is { } postId &&
            !await db.ChannelPosts.AnyAsync(p => p.PostId == postId && p.ChannelId == id, ct))
            return Error(404, "Post not found.");

        // On top of the general "api" limiter: reports create operator work, so
        // they get their own small daily budget per device.
        var report = await channels.ReportAsync(id, request.PostId, me, reason, category, contactEmail, goodFaith, ct);
        if (report is null) return Error(429, "Too many reports, try again later.", "report_limit_reached");

        // The receipt (DSA Art. 16(4)): the number lets the reporter follow the
        // outcome under GET /channels/reports/mine.
        return Results.Ok(new { reportId = report.Id, createdAt = report.CreatedAt });
    }

    // -----------------------------------------------------------------------
    // GET /channels/reports/mine - the outcome of this device's own reports
    // -----------------------------------------------------------------------
    private static async Task<IResult> MyReports(ClaimsPrincipal user, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();

        // Per DEVICE, not per account: reports are filed anonymously by a
        // device and an anonymous device has no account to group by.
        // Deleted channels are included on purpose: "the channel was
        // terminated" is exactly the outcome a reporter wants to see.
        var reports = await db.ChannelReports.AsNoTracking()
            .Where(r => r.ReporterDeviceId == me)
            .OrderByDescending(r => r.CreatedAt)
            .Take(100)
            .Select(r => new
            {
                reportId = r.Id,
                channelId = r.ChannelId,
                channelName = r.Channel.Name,
                channelHandle = r.Channel.Handle,
                postId = r.PostId,
                category = r.Category,
                createdAt = r.CreatedAt,
                status = r.Status,
                resolvedAt = r.ResolvedAt
            })
            .ToListAsync(ct);
        return Results.Ok(reports);
    }

    // -----------------------------------------------------------------------
    // GET /channels/{id}/moderation - statements of reasons (owner/admin/publisher)
    // -----------------------------------------------------------------------
    private static async Task<IResult> ModerationStatements(
        Guid id, ClaimsPrincipal user, ChannelService channels, AppDbContext db, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();

        // A terminated channel is a soft-deleted one, invisible to everybody
        // else; its OWNER must still be able to read why (DSA Art. 17), so
        // the owner check goes by account and ignores DeletedAt.
        var channel = await db.Channels.AsNoTracking().FirstOrDefaultAsync(c => c.ChannelId == id, ct);
        if (channel is null) return ChannelNotFound();
        var role = await channels.GetRoleAsync(channel, me, ct);
        if (channel.DeletedAt is not null && role != ChannelRole.Owner) return ChannelNotFound();
        if (role == ChannelRole.None) return Results.Forbid();

        // dismiss is left out: nothing happened to the channel, and listing it
        // would tell the owner that somebody reported them.
        var statements = await db.ModerationDecisions.AsNoTracking()
            .Where(d => d.ChannelId == id && d.Action != ModerationService.Dismiss)
            .OrderByDescending(d => d.CreatedAt)
            .Take(50)
            .ToListAsync(ct);
        return Results.Ok(statements.Select(ModerationService.StatementDto));
    }

    // -----------------------------------------------------------------------
    // Attachments — unencrypted images in the "channel-media" container
    // -----------------------------------------------------------------------
    private static async Task<IResult> UploadAttachment(
        Guid id, IFormFile file, ClaimsPrincipal user, ChannelService channels,
        BlobServiceClient blobService, IOptions<ChannelsOptions> options, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        if (await channels.GetRoleAsync(channel, me, ct) == ChannelRole.None) return Results.Forbid();

        if (file.Length > options.Value.MaxImageBytes)
            return Error(413, "Image is too large.", "image_too_large");
        if (file.Length <= 0) return Error(400, "File must not be empty.");
        if (!ImageExtensions.TryGetValue(file.ContentType ?? "", out var extension))
            return Error(415, "Only JPEG, PNG, WebP and GIF images are allowed.", "unsupported_image_type");

        // ponytail: an uploaded image that never ends up in a post stays in the
        // container forever (only admins can upload, <= 2 MiB each). Add a sweep
        // of blobs unreferenced by ChannelPosts if storage cost ever shows it.
        var name = $"{Guid.NewGuid():N}.{extension}";
        var container = blobService.GetBlobContainerClient(ContainerName);
        await container.CreateIfNotExistsAsync(cancellationToken: ct);

        await using var stream = file.OpenReadStream();
        await container.GetBlobClient($"{id}/{name}").UploadAsync(stream, new BlobUploadOptions
        {
            // Stored with the whitelisted type so the download can never be
            // served as HTML, whatever the bytes really are.
            HttpHeaders = new BlobHttpHeaders { ContentType = file.ContentType }
        }, ct);

        return Results.Created(
            $"/channels/{id}/attachments/{name}",
            new { blobPath = $"{ContainerName}/{id}/{name}", name });
    }

    private static async Task<IResult> DownloadAttachment(
        Guid id, string name, ClaimsPrincipal user, HttpContext http, ChannelService channels,
        BlobServiceClient blobService, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) is not { } me) return Results.Unauthorized();
        if (await channels.FindAsync(id, ct) is not { } channel) return ChannelNotFound();
        var role = await channels.GetRoleAsync(channel, me, ct);
        if (!await channels.IsFollowingAsync(id, me, ct) && role == ChannelRole.None)
            return Results.Forbid();
        // Same visibility as the feed: images of a suspended channel are hidden too.
        if (role == ChannelRole.None && channel.IsSuspended(DateTimeOffset.UtcNow)) return Suspended();

        if (!AttachmentName().IsMatch(name)) return Error(404, "Attachment not found.");

        var blob = blobService.GetBlobContainerClient(ContainerName).GetBlobClient($"{id}/{name}");
        if (!await blob.ExistsAsync(ct)) return Error(404, "Attachment not found.");

        // Content type from OUR extension, not from anything stored or sniffed,
        // plus nosniff: a browser must never interpret user content as a page.
        var contentType = ImageExtensions.First(e => e.Value == name[(name.LastIndexOf('.') + 1)..]).Key;
        http.Response.Headers.XContentTypeOptions = "nosniff";

        var download = await blob.DownloadStreamingAsync(cancellationToken: ct);
        return Results.Stream(download.Value.Content, contentType);
    }
}

// ---------------------------------------------------------------------------
// Request DTOs (responses are anonymous objects built next to the anonymity
// comments above, so the exposed fields are visible in one place)
// ---------------------------------------------------------------------------

public record CreateChannelRequest(string? Name, string? Description);
public record UpdateChannelRequest(string? Name, string? Description);
public record CreatePostRequest(Guid PostId, string? Kind, JsonElement Body, string? AttachmentBlobPath);
public record ReactionRequest(string? Emoji);
public record VoteRequest(int? OptionIndex);
public record ReportRequest(Guid? PostId, string? Reason, string? Category = null, string? ContactEmail = null, bool? GoodFaith = null);
public record AddAdminRequest(string? Role);
