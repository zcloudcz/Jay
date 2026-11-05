// ---------------------------------------------------------------------------
// DeviceListEndpoints.cs - multi-device: store and serve signed device lists
// ---------------------------------------------------------------------------
// PUT /devices/{primaryId}/device-list - the primary uploads a new version.
// GET /devices/{id}/device-list        - anyone fetches the list an id is in.
//
// The server checks shape and bookkeeping only (who may write, version grows,
// a device is in one list). It does NOT verify the signature: clients do,
// against a key they pinned themselves. A server that lies here can cause
// failed sends, never an extra reader.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Npgsql;
using CallType.Api.Data;
using CallType.Api.Hubs;
using CallType.Api.Models;

namespace CallType.Api.Endpoints;

public static class DeviceListEndpoints
{
    /// <summary>Mirrors maxCompanionDevices in calltype_core/lib/crypto/device_list.dart.</summary>
    private const int MaxCompanions = 5;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Cache key written by MessengerHub.LinkConsent: the companion itself,
    /// authenticated, said "I join this primary". In memory on purpose: the
    /// API is exactly one instance and linking is interactive (minutes).
    /// </summary>
    internal static string ConsentKey(Guid companion, Guid primary) => $"link-consent:{companion}:{primary}";

    public static WebApplication MapDeviceListEndpoints(this WebApplication app)
    {
        app.MapPut("/devices/{primaryId:guid}/device-list", PutDeviceList).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/devices/{id:guid}/device-list", GetDeviceList).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static IResult Bad(string error) => Results.BadRequest(new { error });
    private static IResult Conflict(string error) => Results.Conflict(new { error });

    private static async Task<IResult> PutDeviceList(
        Guid primaryId, PutDeviceListRequest request, ClaimsPrincipal user,
        AppDbContext db, IHubContext<MessengerHub> hub, IMemoryCache cache, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) != primaryId) return Results.Forbid();

        byte[] payload, signature;
        try
        {
            payload = Convert.FromBase64String(request.Payload ?? "");
            signature = Convert.FromBase64String(request.Signature ?? "");
        }
        catch (FormatException) { return Bad("device_list_malformed"); }
        if (payload.Length == 0 || payload.Length > 8 * 1024 || signature.Length != 64)
            return Bad("device_list_malformed");

        DeviceListPayload? parsed;
        try { parsed = JsonSerializer.Deserialize<DeviceListPayload>(payload, JsonOptions); }
        catch (JsonException) { parsed = null; }
        if (parsed?.Devices is null || parsed.PrimaryDeviceId != primaryId
            // int.MaxValue could never be superseded, the list would be stuck.
            || parsed.Version < 1 || parsed.Version >= int.MaxValue)
            return Bad("device_list_malformed");

        var companions = parsed.Devices.Select(d => d.DeviceId).ToList();
        if (companions.Count > MaxCompanions)
            return Results.UnprocessableEntity(new { error = "device_list_too_large" });
        if (companions.Distinct().Count() != companions.Count || companions.Contains(primaryId))
            return Bad("device_list_malformed");

        // The "one identity per device, in either role" rule below is
        // check-then-act: two concurrent PUTs (P lists C while Q lists P) could
        // both pass the checks and both commit. One global lock serializes all
        // list writes; fine because writes are rare and interactive. The API is
        // a single instance, but the lock lives in Postgres anyway.
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await db.Database.ExecuteSqlRawAsync("SELECT pg_advisory_xact_lock(7261014)", ct);

        var existing = await db.DeviceLists.Include(l => l.Members)
            .FirstOrDefaultAsync(l => l.PrimaryDeviceId == primaryId, ct);
        if (existing is not null && parsed.Version <= existing.Version)
            return Conflict("device_list_version_conflict");

        // A device is in at most one identity, in either role.
        if (await db.DeviceListMembers.AnyAsync(m => m.DeviceId == primaryId, ct))
            return Conflict("device_list_member_conflict");
        if (await db.Devices.CountAsync(d => companions.Contains(d.DeviceId), ct) != companions.Count)
            return Conflict("device_list_unknown_device");
        if (await db.DeviceListMembers.AnyAsync(
                m => companions.Contains(m.DeviceId) && m.PrimaryDeviceId != primaryId, ct)
            || await db.DeviceLists.AnyAsync(
                l => companions.Contains(l.PrimaryDeviceId) && l.Members.Any(), ct))
            return Conflict("device_list_member_conflict");

        // The server cannot check signatures, so it asks the device directly:
        // a NEW companion must have consented through its own authenticated
        // hub call (LinkConsent). Without this, anybody could claim a
        // victim's device and break the victim's routing.
        var newCompanions = companions
            .Where(id => existing is null || existing.Members.All(m => m.DeviceId != id)).ToList();
        if (newCompanions.Any(id => !cache.TryGetValue(ConsentKey(id, primaryId), out _)))
            return Conflict("device_list_consent_missing");

        // Old AND new members hear about the change: a removed device must
        // learn it was removed.
        var notify = (existing?.Members.Select(m => m.DeviceId) ?? [])
            .Concat(companions).Append(primaryId).Distinct().ToList();

        if (existing is null)
        {
            existing = new DeviceList { PrimaryDeviceId = primaryId };
            db.DeviceLists.Add(existing);
        }
        // Diff instead of clear + re-add: EF cannot track a deleted and an
        // added row with the same key in one SaveChanges.
        existing.Members.RemoveAll(m => !companions.Contains(m.DeviceId));
        foreach (var id in companions.Where(id => existing.Members.All(m => m.DeviceId != id)))
            existing.Members.Add(new DeviceListMember { DeviceId = id, PrimaryDeviceId = primaryId });
        existing.Version = parsed.Version;
        existing.Payload = payload;
        existing.Signature = signature;
        existing.UpdatedAt = DateTimeOffset.UtcNow;

        try
        {
            await db.SaveChangesAsync(ct);
            await tx.CommitAsync(ct);
        }
        catch (DbUpdateConcurrencyException) { return Conflict("device_list_version_conflict"); }
        catch (DbUpdateException ex)
            when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation } pg)
        {
            // Defensive (the lock should prevent it): a second first-time PUT hits the list's PK.
            return Conflict(pg.ConstraintName == "PK_DeviceLists"
                ? "device_list_version_conflict" : "device_list_member_conflict");
        }
        // A listed companion deleted itself between the check and the save.
        catch (DbUpdateException ex)
            when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.ForeignKeyViolation })
        { return Conflict("device_list_unknown_device"); }

        foreach (var id in newCompanions)
            cache.Remove(ConsentKey(id, primaryId));

        // The list is already saved: a cancelled request must not look like a failed write.
        foreach (var deviceId in notify)
            if (MessengerHub.TryGetConnection(deviceId, out var connectionId))
                await hub.Clients.Client(connectionId).SendAsync("DeviceListChanged",
                    new { primaryDeviceId = primaryId, version = parsed.Version }, CancellationToken.None);

        return Results.NoContent();
    }

    private static async Task<IResult> GetDeviceList(Guid id, AppDbContext db, CancellationToken ct)
    {
        var primaryId = await db.DeviceListMembers.Where(m => m.DeviceId == id)
            .Select(m => (Guid?)m.PrimaryDeviceId).FirstOrDefaultAsync(ct) ?? id;
        var list = await db.DeviceLists.AsNoTracking().FirstOrDefaultAsync(l => l.PrimaryDeviceId == primaryId, ct);
        return list is null
            ? Results.NotFound()
            : Results.Ok(new DeviceListResponse(list.PrimaryDeviceId, list.Version,
                Convert.ToBase64String(list.Payload), Convert.ToBase64String(list.Signature)));
    }
}

public record PutDeviceListRequest(string? Payload, string? Signature);

public record DeviceListResponse(Guid PrimaryDeviceId, int Version, string Payload, string Signature);

/// <summary>Only the fields the server routes by; the rest of the payload is the clients' business.</summary>
public record DeviceListPayload(Guid PrimaryDeviceId, int Version, List<DeviceListPayloadEntry>? Devices);

public record DeviceListPayloadEntry(Guid DeviceId);
