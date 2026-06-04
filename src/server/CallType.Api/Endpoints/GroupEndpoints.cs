// ---------------------------------------------------------------------------
// GroupEndpoints.cs — Group creation and membership management
// ---------------------------------------------------------------------------
// Groups are a server-side construct for message fan-out: when a member sends
// a group message, the server knows which devices to relay it to. The group
// name is encrypted client-side — the server stores the blob but cannot read
// it. Membership is per-device (not per-account) because each device holds
// its own key material for the group session.
//
// Role model is intentionally simple: "admin" (creator, can manage members)
// and "member" (can send/receive). Stored as a short string for extensibility
// without schema migrations.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Endpoints;

public static class GroupEndpoints
{
    /// <summary>
    /// Registers all group-related routes on the application pipeline.
    /// Called from Program.cs to keep the entry point lean.
    /// </summary>
    public static WebApplication MapGroupEndpoints(this WebApplication app)
    {
        app.MapPost("/groups", CreateGroup);
        app.MapGet("/groups/{groupId:guid}/members", ListMembers);
        app.MapPut("/groups/{groupId:guid}/members", AddMember);
        app.MapDelete("/groups/{groupId:guid}/members/{deviceId:guid}", RemoveMember);
        return app;
    }

    // -----------------------------------------------------------------------
    // POST /groups — Create a new group
    // -----------------------------------------------------------------------
    private static async Task<IResult> CreateGroup(
        CreateGroupRequest request,
        AppDbContext db,
        CancellationToken ct)
    {
        // The creator must be a known device — prevents phantom groups created
        // by non-existent devices from polluting the database.
        var deviceExists = await db.Devices.AnyAsync(d => d.DeviceId == request.CreatedBy, ct);
        if (!deviceExists)
            return Results.BadRequest(new { error = "Device not found." });

        // Decode optional encrypted group name. Null is fine (ad-hoc chats).
        byte[]? nameEncryptedBytes = null;
        if (!string.IsNullOrWhiteSpace(request.NameEncrypted))
        {
            try
            {
                nameEncryptedBytes = Convert.FromBase64String(request.NameEncrypted);
            }
            catch (FormatException)
            {
                return Results.BadRequest(new { error = "NameEncrypted must be valid base64." });
            }
        }

        var now = DateTimeOffset.UtcNow;
        var group = new Group
        {
            GroupId = Guid.NewGuid(),
            CreatedBy = request.CreatedBy,
            NameEncrypted = nameEncryptedBytes,
            CreatedAt = now
        };

        // The creator is automatically added as admin. Without this, the group
        // would have no admin and no one could manage membership.
        var creatorMember = new GroupMember
        {
            GroupId = group.GroupId,
            DeviceId = request.CreatedBy,
            Role = "admin",
            JoinedAt = now
        };

        db.Groups.Add(group);
        db.GroupMembers.Add(creatorMember);
        await db.SaveChangesAsync(ct);

        return Results.Created(
            $"/groups/{group.GroupId}",
            new CreateGroupResponse(group.GroupId));
    }

    // -----------------------------------------------------------------------
    // GET /groups/{groupId}/members — List group members
    // -----------------------------------------------------------------------
    private static async Task<IResult> ListMembers(
        Guid groupId,
        AppDbContext db,
        CancellationToken ct)
    {
        // If there are no members, the group effectively doesn't exist
        // (groups are always created with at least one member — the creator).
        var members = await db.GroupMembers
            .Where(gm => gm.GroupId == groupId)
            .Select(gm => new GroupMemberDto(gm.DeviceId, gm.Role, gm.JoinedAt))
            .ToListAsync(ct);

        if (members.Count == 0)
            return Results.NotFound(new { error = "Group not found." });

        return Results.Ok(members);
    }

    // -----------------------------------------------------------------------
    // PUT /groups/{groupId}/members — Add a member
    // -----------------------------------------------------------------------
    private static async Task<IResult> AddMember(
        Guid groupId,
        AddGroupMemberRequest request,
        AppDbContext db,
        CancellationToken ct)
    {
        // Verify the group exists by checking for at least one member
        // (cheaper than loading the Group entity; same semantic).
        var groupExists = await db.GroupMembers.AnyAsync(gm => gm.GroupId == groupId, ct);
        if (!groupExists)
            return Results.NotFound(new { error = "Group not found." });

        // The device must exist in the Devices table — we don't want to add phantom
        // members that have no key material and can never actually decrypt messages.
        if (!await db.Devices.AnyAsync(d => d.DeviceId == request.DeviceId, ct))
            return Results.BadRequest(new { error = "Device not found." });

        // Prevent duplicate membership — the composite PK would reject it anyway,
        // but returning 409 is a better client experience than a 500 from a DB error.
        var alreadyMember = await db.GroupMembers
            .AnyAsync(gm => gm.GroupId == groupId && gm.DeviceId == request.DeviceId, ct);
        if (alreadyMember)
            return Results.Conflict(new { error = "Device is already a member of this group." });

        db.GroupMembers.Add(new GroupMember
        {
            GroupId = groupId,
            DeviceId = request.DeviceId,
            Role = "member",
            JoinedAt = DateTimeOffset.UtcNow
        });

        await db.SaveChangesAsync(ct);
        return Results.Ok(new { message = "Member added." });
    }

    // -----------------------------------------------------------------------
    // DELETE /groups/{groupId}/members/{deviceId} — Remove a member
    // -----------------------------------------------------------------------
    private static async Task<IResult> RemoveMember(
        Guid groupId,
        Guid deviceId,
        AppDbContext db,
        CancellationToken ct)
    {
        var member = await db.GroupMembers
            .FirstOrDefaultAsync(gm => gm.GroupId == groupId && gm.DeviceId == deviceId, ct);

        if (member is null)
            return Results.NotFound(new { error = "Member not found in this group." });

        db.GroupMembers.Remove(member);
        await db.SaveChangesAsync(ct);

        return Results.Ok(new { message = "Member removed." });
    }
}

// ---------------------------------------------------------------------------
// Request / Response DTOs
// ---------------------------------------------------------------------------

public record CreateGroupRequest(Guid CreatedBy, string? NameEncrypted);
public record CreateGroupResponse(Guid GroupId);
public record AddGroupMemberRequest(Guid DeviceId);
public record GroupMemberDto(Guid DeviceId, string Role, DateTimeOffset JoinedAt);
