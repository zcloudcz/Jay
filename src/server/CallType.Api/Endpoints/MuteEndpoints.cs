// ---------------------------------------------------------------------------
// MuteEndpoints.cs - Per-device conversation mutes (bot conversations D6)
// ---------------------------------------------------------------------------
// A mute only stops the push for the muting device; messages are still
// queued and delivered. The caller device always comes from the JWT, so a
// device can only ever read or change its own mutes.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using Microsoft.EntityFrameworkCore;

namespace CallType.Api.Endpoints;

public static class MuteEndpoints
{
    public static WebApplication MapMuteEndpoints(this WebApplication app)
    {
        app.MapPut("/groups/{groupId:guid}/mute", PutGroupMute).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/mutes/direct/{peerDeviceId:guid}", PutDirectMute).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/mutes", ListMutes).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static IResult? Validate(MuteRequest request) =>
        request.Mode is null || !ConversationMute.Modes.Contains(request.Mode)
            ? Results.Problem(title: "Invalid mute", detail: "mode must be one of: off, bots, all.",
                statusCode: StatusCodes.Status400BadRequest,
                extensions: new Dictionary<string, object?> { ["error"] = "invalid_mode" })
            : null;

    /// <summary>
    /// Member-gated by IDENTITY (like GET /groups/{id}): a companion receives
    /// the group's messages and pushes too, so it must be able to mute it,
    /// even though only its primary is the member.
    /// </summary>
    private static async Task<IResult> PutGroupMute(Guid groupId, MuteRequest request, ClaimsPrincipal user,
        AppDbContext db, DeviceListService deviceLists, ConversationMuteService mutes, CancellationToken ct)
    {
        var caller = AccountEndpoints.CallerDeviceId(user);
        if (caller is null) return Results.Unauthorized();
        var denial = await GroupEndpoints.Authorize(groupId, await deviceLists.PrimaryOfAsync(caller.Value, ct), db, false, ct);
        if (denial != null) return denial;
        if (Validate(request) is { } invalid) return invalid;
        await mutes.SetAsync(caller.Value, groupId, null, request.Mode!, request.Until, ct);
        return Results.NoContent();
    }

    /// <summary>
    /// Mutes the 1:1 conversation with the peer's IDENTITY. Any device of the
    /// peer may be passed; it is resolved to the primary exactly like the hub
    /// resolves senderPrimary on delivery, which is what the push check
    /// compares against. No "is there a conversation" check: the server does
    /// not know who talks to whom beyond queued blobs, and muting a stranger
    /// up front is harmless.
    /// </summary>
    private static async Task<IResult> PutDirectMute(Guid peerDeviceId, MuteRequest request, ClaimsPrincipal user,
        AppDbContext db, DeviceListService deviceLists, ConversationMuteService mutes, CancellationToken ct)
    {
        var caller = AccountEndpoints.CallerDeviceId(user);
        if (caller is null) return Results.Unauthorized();
        if (!await db.Devices.AnyAsync(d => d.DeviceId == peerDeviceId, ct)) return Results.NotFound();
        if (Validate(request) is { } invalid) return invalid;
        var (callerPrimary, peerPrimary) = await deviceLists.PrimariesOfAsync(caller.Value, peerDeviceId, ct);
        // Own devices never push each other (FanoutAsync skips the sender's
        // identity), so a self mute could only ever be a client bug.
        if (callerPrimary == peerPrimary)
            return Results.Problem(title: "Invalid mute", detail: "Cannot mute your own identity.",
                statusCode: StatusCodes.Status400BadRequest,
                extensions: new Dictionary<string, object?> { ["error"] = "cannot_mute_self" });
        await mutes.SetAsync(caller.Value, null, peerPrimary, request.Mode!, request.Until, ct);
        return Results.NoContent();
    }

    private static async Task<IResult> ListMutes(ClaimsPrincipal user, ConversationMuteService mutes, CancellationToken ct)
    {
        var caller = AccountEndpoints.CallerDeviceId(user);
        if (caller is null) return Results.Unauthorized();
        return Results.Ok(await mutes.ListAsync(caller.Value, ct));
    }
}

public record MuteRequest(string? Mode, DateTimeOffset? Until);
