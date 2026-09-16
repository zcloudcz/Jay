using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Endpoints;

public static class GroupEndpoints
{
    public static WebApplication MapGroupEndpoints(this WebApplication app)
    {
        app.MapPost("/groups", CreateGroup).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/groups/{groupId:guid}/members", ListMembers).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/groups/{groupId:guid}/members", AddMember).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/groups/{groupId:guid}/members/{deviceId:guid}", RemoveMember).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static Guid Caller(ClaimsPrincipal user) => Guid.TryParse(
        user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub"), out var id) ? id : Guid.Empty;

    private static async Task<IResult> CreateGroup(CreateGroupRequest request, ClaimsPrincipal user,
        AppDbContext db, CancellationToken ct)
    {
        var creator = Caller(user);
        if (creator == Guid.Empty) return Results.Unauthorized();
        var members = (request.MemberDeviceIds ?? []).Append(creator).Distinct().ToArray();
        if (members.Length > 100 || members.Contains(Guid.Empty))
            return Results.BadRequest(new { error = "Groups support up to 100 valid devices." });
        if (await db.Devices.CountAsync(d => members.Contains(d.DeviceId), ct) != members.Length)
            return Results.BadRequest(new { error = "Device not found." });
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

    private static async Task<IResult?> Authorize(Guid groupId, ClaimsPrincipal user,
        AppDbContext db, bool admin, CancellationToken ct)
    {
        if (!await db.Groups.AnyAsync(g => g.GroupId == groupId, ct)) return Results.NotFound();
        var caller = Caller(user);
        var role = await db.GroupMembers.Where(m => m.GroupId == groupId && m.DeviceId == caller)
            .Select(m => m.Role).SingleOrDefaultAsync(ct);
        return role == null || (admin && role != "admin") ? Results.Forbid() : null;
    }

    private static async Task<IResult> ListMembers(Guid groupId, ClaimsPrincipal user,
        AppDbContext db, CancellationToken ct)
    {
        var denial = await Authorize(groupId, user, db, false, ct);
        if (denial != null) return denial;
        var members = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Select(m => new GroupMemberDto(m.DeviceId, m.Role, m.JoinedAt)).ToListAsync(ct);
        return Results.Ok(members);
    }

    private static async Task<IResult> AddMember(Guid groupId, AddGroupMemberRequest request,
        ClaimsPrincipal user, AppDbContext db, CancellationToken ct)
    {
        var denial = await Authorize(groupId, user, db, true, ct);
        if (denial != null) return denial;
        if (!await db.Devices.AnyAsync(d => d.DeviceId == request.DeviceId, ct))
            return Results.BadRequest(new { error = "Device not found." });
        if (await db.GroupMembers.AnyAsync(m => m.GroupId == groupId && m.DeviceId == request.DeviceId, ct))
            return Results.Conflict(new { error = "Device is already a member." });
        if (await db.GroupMembers.CountAsync(m => m.GroupId == groupId, ct) >= 100)
            return Results.BadRequest(new { error = "Group is full." });
        db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = request.DeviceId,
            Role = "member", JoinedAt = DateTimeOffset.UtcNow });
        await db.SaveChangesAsync(ct);
        return Results.Ok(new { message = "Member added." });
    }

    private static async Task<IResult> RemoveMember(Guid groupId, Guid deviceId, ClaimsPrincipal user,
        AppDbContext db, CancellationToken ct)
    {
        var denial = await Authorize(groupId, user, db, true, ct);
        if (denial != null) return denial;
        var member = await db.GroupMembers.SingleOrDefaultAsync(m => m.GroupId == groupId && m.DeviceId == deviceId, ct);
        if (member == null) return Results.NotFound();
        if (member.Role == "admin" && await db.GroupMembers.CountAsync(m => m.GroupId == groupId && m.Role == "admin", ct) <= 1)
            return Results.Conflict(new { error = "The last administrator cannot be removed." });
        db.GroupMembers.Remove(member);
        await db.SaveChangesAsync(ct);
        return Results.Ok(new { message = "Member removed." });
    }
}

public record CreateGroupRequest(Guid[]? MemberDeviceIds);
public record CreateGroupResponse(Guid GroupId);
public record AddGroupMemberRequest(Guid DeviceId);
public record GroupMemberDto(Guid DeviceId, string Role, DateTimeOffset JoinedAt);
