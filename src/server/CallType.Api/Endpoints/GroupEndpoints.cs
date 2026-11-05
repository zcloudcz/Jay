using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Configuration;
using CallType.Api.Data;
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
    private static async Task<IResult?> Authorize(Guid groupId, Guid caller,
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
        AppDbContext db, HttpContext http, BusinessModeOptions businessMode, DeviceListService deviceLists, CancellationToken ct)
    {
        var denial = await Authorize(groupId, await deviceLists.PrimaryOfAsync(Caller(user), ct), db, false, ct);
        if (denial != null) return denial;
        var organizationId = await db.Groups.Where(g => g.GroupId == groupId)
            .Select(g => g.OrganizationId).SingleAsync(ct);
        if (organizationId is null || !businessMode.Enabled)
            return Results.Ok(new GroupInfoDto(groupId, null, null, null));
        var auditorDeviceId = await db.GroupMembers
            .Where(m => m.GroupId == groupId && m.Role == "auditor")
            .Select(m => (Guid?)m.DeviceId).SingleOrDefaultAsync(ct);
        var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();
        var organizationName = await auditDb.Organizations.AsNoTracking()
            .Where(o => o.OrganizationId == organizationId).Select(o => o.Name).SingleOrDefaultAsync(ct);
        return Results.Ok(new GroupInfoDto(groupId, organizationId, organizationName, auditorDeviceId));
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
        ClaimsPrincipal user, AppDbContext db, HttpContext http, CancellationToken ct)
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
        return Results.Ok(new { message = "Member added." });
    }

    private static async Task<IResult> RemoveMember(Guid groupId, Guid deviceId, ClaimsPrincipal user,
        AppDbContext db, CancellationToken ct)
    {
        var denial = await Authorize(groupId, Caller(user), db, true, ct);
        if (denial != null) return denial;
        var member = await db.GroupMembers.SingleOrDefaultAsync(m => m.GroupId == groupId && m.DeviceId == deviceId, ct);
        if (member == null) return Results.NotFound();
        // KB1: the organization's archive member is a legal invariant, not an
        // ordinary admin decision — it can never be removed via this endpoint.
        if (member.Role == "auditor")
            return Results.Conflict(new { error = "auditor_immutable" });
        if (member.Role == "admin" && await db.GroupMembers.CountAsync(m => m.GroupId == groupId && m.Role == "admin", ct) <= 1)
            return Results.Conflict(new { error = "The last administrator cannot be removed." });
        db.GroupMembers.Remove(member);
        await db.SaveChangesAsync(ct);
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
public record GroupInfoDto(Guid GroupId, Guid? OrganizationId, string? OrganizationName, Guid? AuditorDeviceId);
