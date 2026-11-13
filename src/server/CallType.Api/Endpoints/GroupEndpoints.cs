using System.Security.Claims;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Hubs;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Endpoints;

public static class GroupEndpoints
{
    public static WebApplication MapGroupEndpoints(this WebApplication app)
    {
        app.MapPost("/groups", CreateGroup).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/groups/business", CreateBusinessGroup).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/groups/{groupId:guid}", GetGroup).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/groups/{groupId:guid}/members", ListMembers).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/groups/{groupId:guid}/members", AddMember).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/groups/{groupId:guid}/members/{deviceId:guid}", RemoveMember).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/groups/{groupId:guid}/bot-talk", PutBotTalk).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/groups/{groupId:guid}/members/{deviceId:guid}/role", PutMemberRole).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/groups/{groupId:guid}/topic", PutTopic).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static Guid Caller(ClaimsPrincipal user) => Guid.TryParse(
        user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub"), out var id) ? id : Guid.Empty;

    private static async Task<IResult> CreateGroup(CreateGroupRequest request, ClaimsPrincipal user,
        AppDbContext db, HttpContext http, DeviceListService deviceLists, CancellationToken ct)
    {
        var creator = Caller(user);
        if (creator == Guid.Empty) return Results.Unauthorized();
        // Multi-device: a companion would become a member on its own and the
        // rest of its identity would never see the group (spec "Limits of v1").
        // Groups are created and managed from the primary device.
        if (await deviceLists.PrimaryOfAsync(creator, ct) != creator)
            return Results.Json(new { error = "companion_cannot_manage_groups" }, statusCode: 403);
        var members = (request.MemberDeviceIds ?? []).Append(creator).Distinct().ToArray();
        if (members.Length > 100 || members.Contains(Guid.Empty))
            return Results.BadRequest(new { error = "Groups support up to 100 valid devices." });
        if (await db.Devices.CountAsync(d => members.Contains(d.DeviceId), ct) != members.Length)
            return Results.BadRequest(new { error = "Device not found." });

        // P1: this is an anonymous group — creator vs each new member.
        var communicationPolicy = http.RequestServices.GetRequiredService<OrgCommunicationPolicy>();
        foreach (var member in members.Where(id => id != creator))
            if (!await communicationPolicy.IsAllowedAsync(creator, member, ct))
                return Results.Json(new { error = "business_conversation_required", code = "business_conversation_required" }, statusCode: 409);

        var now = DateTimeOffset.UtcNow;
        var group = new Group { GroupId = Guid.NewGuid(), CreatedBy = creator, CreatedAt = now };
        db.Groups.Add(group);
        db.GroupMembers.AddRange(members.Select(device => new GroupMember {
            GroupId = group.GroupId, DeviceId = device,
            Role = device == creator ? "admin" : "member", JoinedAt = now
        }));
        await db.SaveChangesAsync(ct);
        return Results.Created($"/groups/{group.GroupId}", new CreateGroupResponse(group.GroupId));
    }

    /// <summary>
    /// Business group creation (plan §1, KB1): a separate endpoint rather than
    /// an optional field on the existing request, so the anonymous /groups
    /// path (by far the common case) stays untouched and this one can enforce
    /// its own auditor/enrollment rules without an if-branch in the middle of
    /// it. A business 1:1 is the same call with one other member.
    /// </summary>
    private static async Task<IResult> CreateBusinessGroup(CreateBusinessGroupRequest request, ClaimsPrincipal user,
        HttpContext http, BusinessModeOptions businessMode, CancellationToken ct)
    {
        if (!businessMode.Enabled) return Results.Json(new { error = "business_mode_disabled" }, statusCode: 503);
        var creator = Caller(user);
        if (creator == Guid.Empty) return Results.Unauthorized();

        var service = http.RequestServices.GetRequiredService<BusinessGroupService>();
        var result = await service.CreateAsync(request.OrganizationId, creator, request.MemberDeviceIds ?? [], ct);
        if (!result.Success)
            return result.ErrorCode switch
            {
                "auditor_not_configured" => Results.Conflict(new { error = result.ErrorCode }),
                "not_enrolled" => Results.Forbid(),
                "auditor_unavailable" => Results.Json(new { error = result.ErrorCode, code = "auditor_unavailable" }, statusCode: 503),
                _ => Results.BadRequest(new { error = result.ErrorCode })
            };
        return Results.Created($"/groups/{result.GroupId}", new CreateGroupResponse(result.GroupId));
    }

    /// <summary>
    /// [caller] is the IDENTITY for the read-only endpoints (a companion reads
    /// the groups of its primary; it is not a member itself) and the raw
    /// device for membership changes, which stay with the member device.
    /// </summary>
    internal static async Task<IResult?> Authorize(Guid groupId, Guid caller,
        AppDbContext db, bool admin, CancellationToken ct)
    {
        if (!await db.Groups.AnyAsync(g => g.GroupId == groupId, ct)) return Results.NotFound();
        var role = await db.GroupMembers.Where(m => m.GroupId == groupId && m.DeviceId == caller)
            .Select(m => m.Role).SingleOrDefaultAsync(ct);
        return role == null || (admin && role != "admin") ? Results.Forbid() : null;
    }

    /// <summary>
    /// GET /groups/{id} — business metadata for the KB1 banner. The client
    /// must show "archived by <organization>" and the auditor tile without a
    /// per-member round trip, so the organization name (which lives in the
    /// audit DB) is resolved here once. Anonymous groups return nulls.
    /// </summary>
    private static async Task<IResult> GetGroup(Guid groupId, ClaimsPrincipal user,
        AppDbContext db, HttpContext http, BusinessModeOptions businessMode, DeviceListService deviceLists,
        ConversationMuteService mutes, CancellationToken ct)
    {
        var caller = Caller(user);
        var denial = await Authorize(groupId, await deviceLists.PrimaryOfAsync(caller, ct), db, false, ct);
        if (denial != null) return denial;
        var group = await db.Groups.AsNoTracking().Where(g => g.GroupId == groupId)
            .Select(g => new { g.OrganizationId, g.BotTalk, g.TopicVersion, g.TopicUpdatedBy, g.TopicUpdatedAt })
            .SingleAsync(ct);
        var organizationId = group.OrganizationId;
        var botTalk = await BotTalkDtoAsync(groupId, group.BotTalk, db, ct);
        var topic = TopicDto(group.TopicVersion, group.TopicUpdatedBy, group.TopicUpdatedAt);
        // Mutes are per DEVICE: a companion reading its identity's group gets
        // its own mute, not the primary's.
        var myMute = await mutes.GetAsync(caller, groupId, null, ct);
        if (organizationId is null || !businessMode.Enabled)
            return Results.Ok(new GroupInfoDto(groupId, null, null, null, botTalk, myMute, topic));
        var auditorDeviceId = await db.GroupMembers
            .Where(m => m.GroupId == groupId && m.Role == "auditor")
            .Select(m => (Guid?)m.DeviceId).SingleOrDefaultAsync(ct);
        var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();
        var organizationName = await auditDb.Organizations.AsNoTracking()
            .Where(o => o.OrganizationId == organizationId).Select(o => o.Name).SingleOrDefaultAsync(ct);
        return Results.Ok(new GroupInfoDto(groupId, organizationId, organizationName, auditorDeviceId, botTalk, myMute, topic));
    }

    /// <summary>
    /// Contract shape of the setting. The allowed list is intersected with
    /// the current bot members on read: RemoveMember prunes it, but a device
    /// deleted through PrivacyEndpoints (raw SQL, cascade) or an enrollment
    /// revocation path may leave a stale id behind, and bots must never see
    /// a non-member as allowed. One query, and only when the list is non-empty.
    /// </summary>
    private static async Task<BotTalkDto> BotTalkDtoAsync(Guid groupId, GroupBotTalk botTalk,
        AppDbContext db, CancellationToken ct)
    {
        var allowed = botTalk.AllowedBotDeviceIds;
        if (allowed.Count > 0)
        {
            var current = await db.GroupMembers
                .Where(m => m.GroupId == groupId && allowed.Contains(m.DeviceId) && m.Device.IsBot)
                .Select(m => m.DeviceId).ToListAsync(ct);
            allowed = allowed.Where(current.Contains).ToList();
        }
        return BotTalkDto.From(botTalk, allowed);
    }

    /// <summary>Null when no topic was ever recorded (the contract's "never set").</summary>
    private static GroupTopicDto? TopicDto(long? version, Guid? updatedBy, DateTimeOffset? updatedAt) =>
        version is { } v && updatedBy is { } by ? new GroupTopicDto(v, by, updatedAt) : null;

    private static IResult InvalidBotTalk(string error, string detail) => Results.Problem(
        title: "Invalid bot talk setting", detail: detail, statusCode: StatusCodes.Status400BadRequest,
        // "error" mirrors the {error} field of the other group endpoints so
        // clients can branch on one machine-readable code everywhere.
        extensions: new Dictionary<string, object?> { ["error"] = error });

    /// <summary>
    /// PUT /groups/{id}/bot-talk - admin only, the exact gate AddMember and
    /// RemoveMember use (404 unknown group, 403 non-member, non-admin or
    /// companion device). Omitted numbers keep their current value, so a
    /// client that only flips the mode cannot reset the limits by accident.
    /// </summary>
    private static async Task<IResult> PutBotTalk(Guid groupId, BotTalkRequest request, ClaimsPrincipal user,
        AppDbContext db, DeviceListService deviceLists, IHubContext<MessengerHub> hub, TimeProvider clock,
        CancellationToken ct)
    {
        var caller = Caller(user);
        var denial = await Authorize(groupId, caller, db, true, ct);
        if (denial != null) return denial;

        if (request.Mode is null || !GroupBotTalk.Modes.Contains(request.Mode))
            return InvalidBotTalk("invalid_mode", "mode must be one of: off, all, selected.");
        if (request.MaxBotTurns is { } turns && (turns < GroupBotTalk.MinMaxBotTurns || turns > GroupBotTalk.MaxMaxBotTurns))
            return InvalidBotTalk("invalid_max_bot_turns",
                $"maxBotTurns must be between {GroupBotTalk.MinMaxBotTurns} and {GroupBotTalk.MaxMaxBotTurns}.");
        if (request.PauseMinutes is { } pause && (pause < GroupBotTalk.MinPauseMinutes || pause > GroupBotTalk.MaxPauseMinutes))
            return InvalidBotTalk("invalid_pause_minutes",
                $"pauseMinutes must be between {GroupBotTalk.MinPauseMinutes} and {GroupBotTalk.MaxPauseMinutes}.");

        var ids = (request.AllowedBotDeviceIds ?? []).Distinct().ToList();
        if (ids.Count > 0)
        {
            // ONE query for the whole list. The auditor is excluded explicitly
            // (design: "the auditor member is never a bot participant") even if
            // its device happens to be registered as a bot.
            var validBots = await db.GroupMembers
                .Where(m => m.GroupId == groupId && ids.Contains(m.DeviceId) && m.Role != "auditor" && m.Device.IsBot)
                .Select(m => m.DeviceId).ToListAsync(ct);
            var invalid = ids.Except(validBots).ToList();
            if (invalid.Count > 0)
                return InvalidBotTalk("not_a_bot_member",
                    "allowedBotDeviceIds must be current bot members of the group: " + string.Join(",", invalid));
        }

        var group = await db.Groups.SingleAsync(g => g.GroupId == groupId, ct);
        group.BotTalk.Mode = request.Mode;
        group.BotTalk.AllowedBotDeviceIds = ids;
        group.BotTalk.MaxBotTurns = request.MaxBotTurns ?? group.BotTalk.MaxBotTurns;
        group.BotTalk.PauseMinutes = request.PauseMinutes ?? group.BotTalk.PauseMinutes;
        // Group topics T3/T4 (spec S4): omitted/null keeps the stored value,
        // so an old app that only flips the mode cannot switch them off.
        group.BotTalk.BotsReadAll = request.BotsReadAll ?? group.BotTalk.BotsReadAll;
        group.BotTalk.ReplyWithoutMention = request.ReplyWithoutMention ?? group.BotTalk.ReplyWithoutMention;
        group.BotTalk.UpdatedBy = caller;
        group.BotTalk.UpdatedAt = clock.GetUtcNow();
        await db.SaveChangesAsync(ct);

        await NotifyGroupChangedAsync(groupId, [], db, deviceLists, hub);
        return Results.Ok(BotTalkDto.From(group.BotTalk, ids));
    }

    private static IResult Error(int status, string code) =>
        // {error, code}: the app reads `code ?? error`, like RemoveMember's last_admin.
        Results.Json(new { error = code, code }, statusCode: status);

    /// <summary>
    /// PUT /groups/{id}/members/{deviceId}/role (spec 2026-11-13-group-topics
    /// S1). Same gate as AddMember (raw caller device must be an admin, so a
    /// companion gets 403). Bots never become admins: an admin can remove
    /// members and change bot settings, which a bot must never do on its own.
    /// The group row is locked for the check-and-write, so two admins demoting
    /// each other at the same time cannot leave the group without an admin.
    /// </summary>
    private static async Task<IResult> PutMemberRole(Guid groupId, Guid deviceId, MemberRoleRequest request,
        ClaimsPrincipal user, AppDbContext db, DeviceListService deviceLists, IHubContext<MessengerHub> hub,
        CancellationToken ct)
    {
        var denial = await Authorize(groupId, Caller(user), db, true, ct);
        if (denial != null) return denial;
        if (request.Role is not ("admin" or "member")) return Error(400, "invalid_role");

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"SELECT 1 FROM \"Groups\" WHERE \"GroupId\" = {groupId} FOR UPDATE", ct);
        // Again under the lock: the caller may have been demoted meanwhile.
        denial = await Authorize(groupId, Caller(user), db, true, ct);
        if (denial != null) return denial;
        var member = await db.GroupMembers.Include(m => m.Device)
            .SingleOrDefaultAsync(m => m.GroupId == groupId && m.DeviceId == deviceId, ct);
        if (member == null) return Error(404, "not_a_member");
        // KB1: the archive member's role is a legal invariant.
        if (member.Role == "auditor") return Error(409, "auditor_immutable");
        if (request.Role == "admin" && member.Device.IsBot) return Error(400, "bot_cannot_be_admin");
        if (member.Role == request.Role)
            return Results.Ok(new MemberRoleDto(deviceId, member.Role));
        if (member.Role == "admin"
            && await db.GroupMembers.CountAsync(m => m.GroupId == groupId && m.Role == "admin", ct) <= 1)
            return Error(409, "last_admin");
        member.Role = request.Role;
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        await NotifyGroupChangedAsync(groupId, [], db, deviceLists, hub);
        return Results.Ok(new MemberRoleDto(deviceId, member.Role));
    }

    /// <summary>
    /// PUT /groups/{id}/topic (spec S2): records a new topic VERSION; the
    /// content never reaches the server (no group key exists, row 9). One
    /// atomic UPDATE ... RETURNING, so concurrent admins get distinct,
    /// strictly increasing versions and each answer names its own caller.
    /// Unix ms as the floor keeps versions increasing even if a group row
    /// were ever restored from an older backup.
    /// </summary>
    private static async Task<IResult> PutTopic(Guid groupId, ClaimsPrincipal user, AppDbContext db,
        DeviceListService deviceLists, IHubContext<MessengerHub> hub, TimeProvider clock, CancellationToken ct)
    {
        var caller = Caller(user);
        var denial = await Authorize(groupId, caller, db, true, ct);
        if (denial != null) return denial;
        if (await db.Groups.AnyAsync(g => g.GroupId == groupId && g.OrganizationId != null, ct))
            return Error(409, "business_group");

        var now = clock.GetUtcNow();
        var nowMs = now.ToUnixTimeMilliseconds();
        var record = (await db.Database.SqlQuery<GroupTopicDto>($"""
            UPDATE "Groups"
               SET "TopicVersion" = GREATEST(COALESCE("TopicVersion", 0) + 1, {nowMs}),
                   "TopicUpdatedBy" = {caller},
                   "TopicUpdatedAt" = {now}
             WHERE "GroupId" = {groupId}
            RETURNING "TopicVersion" AS "Version", "TopicUpdatedBy" AS "UpdatedBy", "TopicUpdatedAt" AS "UpdatedAt"
            """).ToListAsync(ct)).Single();

        await NotifyGroupChangedAsync(groupId, [], db, deviceLists, hub);
        return Results.Ok(record);
    }

    /// <summary>
    /// "GroupChanged" hub hint: { groupId }. Carries nothing but the id, so
    /// clients and bots re-read GET /groups/{id} (+ /members) themselves.
    /// There was no such hint before bot conversations; it reuses the
    /// mechanism of the multi-device "DeviceListChanged" event (direct send
    /// to each online device via MessengerHub's connection map; offline
    /// devices re-read on their next start anyway). Sent to every member
    /// device AND their companions, because companions read the groups of
    /// their identity. <paramref name="extra"/> lets RemoveMember reach the
    /// device that was just removed.
    /// </summary>
    internal static async Task NotifyGroupChangedAsync(Guid groupId, IEnumerable<Guid> extra,
        AppDbContext db, DeviceListService deviceLists, IHubContext<MessengerHub> hub)
    {
        // CancellationToken.None: the change is already saved, a client that
        // hung up must not stop the others from hearing about it.
        var members = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Select(m => m.DeviceId).ToListAsync(CancellationToken.None);
        var devices = await deviceLists.DevicesOfAsync(members.Concat(extra).Distinct().ToList(), CancellationToken.None);
        foreach (var deviceId in devices)
            if (MessengerHub.TryGetConnection(deviceId, out var connectionId))
                await hub.Clients.Client(connectionId).SendAsync("GroupChanged", new { groupId }, CancellationToken.None);
    }

    private static async Task<IResult> ListMembers(Guid groupId, ClaimsPrincipal user,
        AppDbContext db, DeviceListService deviceLists, CancellationToken ct)
    {
        var denial = await Authorize(groupId, await deviceLists.PrimaryOfAsync(Caller(user), ct), db, false, ct);
        if (denial != null) return denial;
        // One JOIN instead of a Devices lookup per member (no N+1). The profile
        // fields are the same ones GET /devices/by-handle/{handle} already shows to
        // any authenticated device, so this reveals no new class of information.
        var members = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Join(db.Devices, m => m.DeviceId, d => d.DeviceId,
                (m, d) => new GroupMemberDto(m.DeviceId, m.Role, m.JoinedAt, d.UserHandle, d.DisplayName, d.IsBot))
            .ToListAsync(ct);
        return Results.Ok(members);
    }

    private static async Task<IResult> AddMember(Guid groupId, AddGroupMemberRequest request,
        ClaimsPrincipal user, AppDbContext db, HttpContext http, DeviceListService deviceLists,
        IHubContext<MessengerHub> hub, CancellationToken ct)
    {
        var denial = await Authorize(groupId, Caller(user), db, true, ct);
        if (denial != null) return denial;
        if (!await db.Devices.AnyAsync(d => d.DeviceId == request.DeviceId, ct))
            return Results.BadRequest(new { error = "Device not found." });
        if (await db.GroupMembers.AnyAsync(m => m.GroupId == groupId && m.DeviceId == request.DeviceId, ct))
            return Results.Conflict(new { error = "Device is already a member." });
        if (await db.GroupMembers.CountAsync(m => m.GroupId == groupId, ct) >= 100)
            return Results.BadRequest(new { error = "Group is full." });

        // KB1/KB2: a device joining a business group must be enrolled in the
        // same organization, or it would receive content the auditor never
        // sees archived-to it (the fan-out check in the hub only guards the
        // auditor's own presence, not who else is let in).
        var organizationId = await db.Groups.Where(g => g.GroupId == groupId)
            .Select(g => g.OrganizationId).SingleAsync(ct);
        if (organizationId is { } orgId)
        {
            var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();
            var enrolled = await auditDb.OrgEnrollments.AnyAsync(e =>
                e.OrganizationId == orgId && e.DeviceId == request.DeviceId && e.RevokedAt == null, ct);
            if (!enrolled) return Results.Forbid();
        }
        else
        {
            // P1: adding a member to an ANONYMOUS group is one of the paths
            // RequireBusinessConversations covers — adder vs the new member.
            var communicationPolicy = http.RequestServices.GetRequiredService<OrgCommunicationPolicy>();
            if (!await communicationPolicy.IsAllowedAsync(Caller(user), request.DeviceId, ct))
                return Results.Json(new { error = "business_conversation_required", code = "business_conversation_required" }, statusCode: 409);
        }

        db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = request.DeviceId,
            Role = "member", JoinedAt = DateTimeOffset.UtcNow });
        await db.SaveChangesAsync(ct);
        // "All bots" includes bots added later (D2): bots must learn about
        // the new member, so membership changes send the same hint.
        await NotifyGroupChangedAsync(groupId, [], db, deviceLists, hub);
        return Results.Ok(new { message = "Member added." });
    }

    private static async Task<IResult> RemoveMember(Guid groupId, Guid deviceId, ClaimsPrincipal user,
        AppDbContext db, DeviceListService deviceLists, IHubContext<MessengerHub> hub, CancellationToken ct)
    {
        var caller = Caller(user);
        if (caller == Guid.Empty) return Results.Unauthorized();
        // Leaving (spec 2026-11-09-delete-chats-contacts D5): any device of an
        // identity may remove that identity's own member device, admin or
        // not. Membership lives on the primary, so a companion leaves by
        // removing its primary. Everybody else needs the admin gate.
        var leaving = await deviceLists.PrimaryOfAsync(caller, ct) == await deviceLists.PrimaryOfAsync(deviceId, ct);
        // A non-member "leaving" gets the same 403 as any outsider (Authorize).
        var denial = leaving
            ? await Authorize(groupId, deviceId, db, false, ct)
            : await Authorize(groupId, caller, db, true, ct);
        if (denial != null) return denial;
        var member = await db.GroupMembers.SingleOrDefaultAsync(m => m.GroupId == groupId && m.DeviceId == deviceId, ct);
        if (member == null) return Results.NotFound();
        // KB1: the organization's archive member is a legal invariant, not an
        // ordinary admin decision — it can never be removed via this endpoint.
        if (member.Role == "auditor")
            return Results.Conflict(new { error = "auditor_immutable" });
        if (member.Role == "admin" && await db.GroupMembers.CountAsync(m => m.GroupId == groupId && m.Role == "admin", ct) <= 1)
            return Results.Conflict(new { error = "The last administrator cannot be removed.", code = "last_admin" });
        db.GroupMembers.Remove(member);
        // A removed bot must not stay "allowed": if it were re-added later it
        // would silently regain bot talk without the admin ticking it again.
        // Same SaveChanges as the removal, so the two never disagree.
        await GroupBotTalkPruning.PruneAsync(db, deviceId, [groupId], ct);
        await db.SaveChangesAsync(ct);
        await NotifyGroupChangedAsync(groupId, [deviceId], db, deviceLists, hub);
        return Results.Ok(new { message = "Member removed." });
    }
}

public record CreateGroupRequest(Guid[]? MemberDeviceIds);
public record CreateBusinessGroupRequest(Guid OrganizationId, Guid[]? MemberDeviceIds);
public record CreateGroupResponse(Guid GroupId);
public record AddGroupMemberRequest(Guid DeviceId);
// The last three fields are additive (old clients read only deviceId) and let
// clients offer @mentions and show sender names in groups.
public record GroupMemberDto(Guid DeviceId, string Role, DateTimeOffset JoinedAt,
    string UserHandle, string? DisplayName, bool IsBot);
// BotTalk and MyMute are additive (bot conversations contract); old clients ignore them.
public record GroupInfoDto(Guid GroupId, Guid? OrganizationId, string? OrganizationName, Guid? AuditorDeviceId,
    BotTalkDto BotTalk, MuteDto MyMute, GroupTopicDto? Topic = null);
// BotsReadAll / ReplyWithoutMention are additive (group topics S3/S4).
public record BotTalkDto(string Mode, List<Guid> AllowedBotDeviceIds, int MaxBotTurns, int PauseMinutes,
    DateTimeOffset? UpdatedAt, bool BotsReadAll = false, bool ReplyWithoutMention = false)
{
    public static BotTalkDto From(GroupBotTalk s, List<Guid> allowed) => new(s.Mode, allowed, s.MaxBotTurns,
        s.PauseMinutes, s.UpdatedAt, s.BotsReadAll, s.ReplyWithoutMention);
}
public record BotTalkRequest(string? Mode, Guid[]? AllowedBotDeviceIds, int? MaxBotTurns, int? PauseMinutes,
    bool? BotsReadAll = null, bool? ReplyWithoutMention = null);
// Group topics (spec 2026-11-13-group-topics S1-S3). The topic body is `{}`
// and ignored: the content is E2E and never sent to the server.
public record MemberRoleRequest(string? Role);
public record MemberRoleDto(Guid DeviceId, string Role);
public record GroupTopicDto(long Version, Guid UpdatedBy, DateTimeOffset? UpdatedAt);
