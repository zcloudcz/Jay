// ---------------------------------------------------------------------------
// EmergencyEndpoints.cs — E07: emergency channel (spec 2.3/2.6/2.9, plan §5/§7)
// ---------------------------------------------------------------------------
// Kits/drills/proof mutate CallType.Audit.Emergency.EmergencyAppService
// (Audit DB, KB6 admin-audit trail); anything touching the actual Delivery
// group (create/join/list members, drill push) goes through
// EmergencyGroupService (Delivery DB) and MessengerHub — see those files for
// why the split exists (KB3).
//
// POST /orgs/emergency/enroll is intentionally NOT gated on account_required —
// spec 2.3's whole point is that a device with no working M365/SSO/e-mail
// (and possibly no registered account at all) must still be able to join.
// It uses the stricter "auth" rate-limit policy because the code, while
// 128-bit random, is guessable at scale like any bearer secret.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Hubs;
using CallType.Api.Services;
using CallType.Audit.Domain;
using CallType.Audit.Emergency;

namespace CallType.Api.Endpoints;

public static class EmergencyEndpoints
{
    public static WebApplication MapEmergencyEndpoints(this WebApplication app)
    {
        app.MapPost("/orgs/{id:guid}/emergency/kits", IssueKit).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{id:guid}/emergency/kits", ListKits).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/orgs/{id:guid}/emergency/kits/{kitId:guid}", RevokeKit).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/orgs/emergency/enroll", Enroll).RequireAuthorization().RequireRateLimiting("auth");
        app.MapPost("/orgs/{id:guid}/emergency/drills", StartDrill).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/orgs/{id:guid}/emergency/drills/{drillId:long}/confirm", ConfirmDrill).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/orgs/{id:guid}/emergency/drills/{drillId:long}/complete", CompleteDrill).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{id:guid}/emergency/drills", ListDrills).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{id:guid}/emergency/proof", ExportProof).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/kits
    // -----------------------------------------------------------------
    private static async Task<IResult> IssueKit(Guid id, IssueKitRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            var kit = await service.IssueKitAsync(id, accountId.Value, request.Label, request.Count, DateTimeOffset.UtcNow, ct);

            // KB1: the emergency group must exist with its auditor as soon as
            // the org has an emergency channel at all — first kit issue is that
            // moment. Requires the org's auditor to already be configured
            // (PUT /orgs/{id}/auditor, E01) — 409 otherwise, same convention
            // BusinessGroupService.CreateAsync uses for the same precondition.
            var auditorDeviceId = await http.RequestServices.GetRequiredService<CallType.Audit.Infrastructure.AuditDbContext>()
                .Organizations.Where(o => o.OrganizationId == id).Select(o => o.AuditorDeviceId).SingleAsync(ct);
            if (auditorDeviceId is null)
                return Results.Conflict(new { error = "Organization has no auditor device configured yet.", code = "auditor_not_configured" });

            var groupService = http.RequestServices.GetRequiredService<EmergencyGroupService>();
            await groupService.EnsureGroupAsync(id, auditorDeviceId.Value, ct);

            return Results.Ok(new
            {
                kitId = kit.KitId,
                label = kit.Label,
                issuedAt = kit.IssuedAt,
                recoveryCode = kit.RecoveryCode,
                codes = kit.Codes,
                printable = BuildPrintablePayload(kit)
            });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    /// <summary>Plain-text block suitable for printing/QR-encoding offline — no PDF
    /// library available or needed (spec only asks for something printable).</summary>
    private static string BuildPrintablePayload(IssuedKit kit)
    {
        var sb = new StringBuilder();
        sb.AppendLine("CallType — Emergency channel enrollment kit");
        sb.AppendLine($"Label: {kit.Label}");
        sb.AppendLine($"Issued: {kit.IssuedAt:O}");
        sb.AppendLine("Recovery code (kit-level, keep separately): " + kit.RecoveryCode);
        sb.AppendLine("One-time device codes:");
        foreach (var code in kit.Codes) sb.AppendLine("  " + code);
        sb.AppendLine();
        sb.AppendLine("These codes are shown only once. Each code enrolls exactly one device.");
        return sb.ToString();
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/emergency/kits
    // -----------------------------------------------------------------
    private static async Task<IResult> ListKits(Guid id, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            var kits = await service.ListKitsAsync(id, accountId.Value, ct);
            return Results.Ok(kits.Select(k => new
            {
                kitId = k.KitId, label = k.Label, issuedAt = k.IssuedAt, revokedAt = k.RevokedAt,
                codesTotal = k.CodesTotal, codesRemaining = k.CodesRemaining
            }));
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // DELETE /orgs/{id}/emergency/kits/{kitId}
    // -----------------------------------------------------------------
    private static async Task<IResult> RevokeKit(Guid id, Guid kitId, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            await service.RevokeKitAsync(id, accountId.Value, kitId, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // POST /orgs/emergency/enroll
    // -----------------------------------------------------------------
    private static async Task<IResult> Enroll(EnrollEmergencyRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var deviceId = AccountEndpoints.CallerDeviceId(user);
        if (deviceId is null) return Results.Unauthorized();
        if (string.IsNullOrWhiteSpace(request.Code)) return Results.BadRequest(new { error = "Code is required." });

        var accountId = await deliveryDb.AccountDevices.Where(ad => ad.DeviceId == deviceId)
            .Select(ad => (Guid?)ad.AccountId).FirstOrDefaultAsync(ct);

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            var result = await service.EnrollAsync(request.Code, deviceId.Value, accountId, DateTimeOffset.UtcNow, ct);

            // Delivery-side: join the org's emergency group. The group must
            // already exist (created when the first kit was issued) — if it
            // somehow doesn't (kit issued before E02's auditor was set, then
            // fixed later), there is nothing to add the device to yet.
            var auditorDeviceId = await http.RequestServices.GetRequiredService<CallType.Audit.Infrastructure.AuditDbContext>()
                .Organizations.Where(o => o.OrganizationId == result.OrganizationId).Select(o => o.AuditorDeviceId).SingleAsync(ct);
            if (auditorDeviceId is not null)
            {
                var groupService = http.RequestServices.GetRequiredService<EmergencyGroupService>();
                var groupId = await groupService.EnsureGroupAsync(result.OrganizationId, auditorDeviceId.Value, ct);
                await groupService.AddMemberAsync(groupId, deviceId.Value, ct);
            }

            return Results.Ok(new { organizationId = result.OrganizationId });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/drills
    // -----------------------------------------------------------------
    private static async Task<IResult> StartDrill(Guid id, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http,
        IHubContext<MessengerHub> hub, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            var now = DateTimeOffset.UtcNow;
            var drillId = await service.StartDrillAsync(id, accountId.Value, now, ct);

            // Delivery push: no server-originated group message path exists
            // (see plan note) — the drill is announced as a dedicated hub
            // event to whichever emergency-group members are online right
            // now; the client prompts a Confirm dialog on receipt. Offline
            // members simply never see this drill's prompt (acceptable —
            // reachability during the drill IS what's being measured).
            var groupService = http.RequestServices.GetRequiredService<EmergencyGroupService>();
            var members = await groupService.GetMemberDeviceIdsAsync(id, ct);
            foreach (var deviceId in members)
            {
                if (MessengerHub.TryGetConnectionId(deviceId, out var connectionId))
                    await hub.Clients.Client(connectionId).SendAsync("EmergencyDrill",
                        new { organizationId = id, drillId, startedAt = now }, ct);
            }

            return Results.Ok(new { drillId });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/drills/{drillId}/confirm
    // -----------------------------------------------------------------
    private static async Task<IResult> ConfirmDrill(Guid id, long drillId, ClaimsPrincipal user,
        BusinessModeOptions businessMode, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var deviceId = AccountEndpoints.CallerDeviceId(user);
        if (deviceId is null) return Results.Unauthorized();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            await service.ConfirmDrillAsync(id, drillId, deviceId.Value, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/emergency/drills/{drillId}/complete
    // -----------------------------------------------------------------
    private static async Task<IResult> CompleteDrill(Guid id, long drillId, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            await service.CompleteDrillAsync(id, accountId.Value, drillId, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/emergency/drills
    // -----------------------------------------------------------------
    private static async Task<IResult> ListDrills(Guid id, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            var drills = await service.ListDrillsAsync(id, accountId.Value, ct);
            return Results.Ok(drills.Select(d => new
            {
                drillId = d.DrillId, startedAt = d.StartedAt, completedAt = d.CompletedAt,
                confirmedMemberCount = d.ConfirmedMemberCount, responseTimeSeconds = d.ResponseTime?.TotalSeconds
            }));
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/emergency/proof?format=json|txt
    // -----------------------------------------------------------------
    private static async Task<IResult> ExportProof(Guid id, string? format, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        var service = http.RequestServices.GetRequiredService<EmergencyAppService>();
        try
        {
            var audit = await service.GetProofAuditDataAsync(id, accountId.Value, ct);
            var groupService = http.RequestServices.GetRequiredService<EmergencyGroupService>();
            var memberCount = (await groupService.GetMemberDeviceIdsAsync(id, ct)).Count;
            var emergencyGroupExists = await deliveryDb.Groups.AnyAsync(g => g.OrganizationId == id && g.IsEmergencyChannel, ct);

            var proof = EmergencyProof.Build(audit, emergencyGroupExists, memberCount, DateTimeOffset.UtcNow);

            if (string.Equals(format, "txt", StringComparison.OrdinalIgnoreCase))
                return Results.Text(proof.ToText(), "text/plain");
            return Results.Ok(proof);
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // Shared helpers (mirrors OrganizationEndpoints — kept local since these
    // are private there and E07 must not touch E01's file)
    // -----------------------------------------------------------------

    private static IResult? Gate503(BusinessModeOptions businessMode) => businessMode.Enabled
        ? null
        : Results.Json(new { error = "Business mode is not enabled on this server.", code = "business_mode_disabled" }, statusCode: StatusCodes.Status503ServiceUnavailable);

    private static IResult AccountRequired() => Results.Json(
        new { error = "This action requires a registered account linked to the calling device.", code = "account_required" },
        statusCode: StatusCodes.Status403Forbidden);

    private static async Task<Guid?> RequireAccountAsync(ClaimsPrincipal user, AppDbContext db, CancellationToken ct)
    {
        var deviceId = AccountEndpoints.CallerDeviceId(user);
        if (deviceId is null) return null;
        return await db.AccountDevices.Where(ad => ad.DeviceId == deviceId)
            .Select(ad => (Guid?)ad.AccountId).FirstOrDefaultAsync(ct);
    }

    private static IResult MapViolation(DomainRuleViolation ex) => ex.Code switch
    {
        "org_not_found" or "kit_not_found" or "drill_not_found" => Results.NotFound(new { error = ex.Message, code = ex.Code }),
        "forbidden" => Results.Json(new { error = ex.Message, code = ex.Code }, statusCode: StatusCodes.Status403Forbidden),
        "kit_revoked" or "emergency_code_used" or "emergency_code_invalid" =>
            Results.Json(new { error = ex.Message, code = ex.Code }, statusCode: StatusCodes.Status410Gone),
        "invalid_count" or "invalid_label" => Results.UnprocessableEntity(new { error = ex.Message, code = ex.Code }),
        _ => Results.Conflict(new { error = ex.Message, code = ex.Code })
    };
}

// ---------------------------------------------------------------------------
// Request DTOs
// ---------------------------------------------------------------------------

public record IssueKitRequest(string Label, int Count);
public record EnrollEmergencyRequest(string Code);

// ---------------------------------------------------------------------------
// Proof export — "Doklad o existenci a funkčnosti nouzového kanálu" (spec §10)
// ---------------------------------------------------------------------------

/// <summary>
/// Reproducible: SelfHash covers every other field via fixed-order JSON
/// serialization (System.Text.Json preserves declared property order), so the
/// same underlying data always yields the same hash regardless of when it's
/// exported — GeneratedAt is the only field excluded from the hash on purpose
/// (see BuildCanonicalPayload), otherwise no two exports could ever match.
/// </summary>
public record EmergencyProof(
    Guid OrganizationId, string OrganizationName, bool EmergencyGroupExists, Guid? AuditorDeviceId,
    int EnrolledMemberCount, int KitsIssued, int KitsRevoked,
    DateTimeOffset? LastDrillCompletedAt, int? LastDrillConfirmedMemberCount, double? LastDrillResponseTimeSeconds,
    long ArchiveLastSequence, string? ArchiveLastHash,
    DateTimeOffset GeneratedAt, string SelfHashSha256)
{
    public static EmergencyProof Build(EmergencyProofAuditData a, bool emergencyGroupExists, int enrolledMemberCount, DateTimeOffset generatedAt)
    {
        var payload = new
        {
            a.OrganizationId, a.OrganizationName, emergencyGroupExists, a.AuditorDeviceId, enrolledMemberCount,
            a.KitsIssued, a.KitsRevoked,
            lastDrillCompletedAt = a.LastCompletedDrill?.CompletedAt,
            lastDrillConfirmedMemberCount = a.LastCompletedDrill?.ConfirmedMemberCount,
            lastDrillResponseTimeSeconds = a.LastCompletedDrill?.ResponseTime?.TotalSeconds,
            a.ArchiveLastSequence, a.ArchiveLastHash
        };
        var canonicalJson = JsonSerializer.Serialize(payload);
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(canonicalJson)));

        return new EmergencyProof(a.OrganizationId, a.OrganizationName, emergencyGroupExists, a.AuditorDeviceId,
            enrolledMemberCount, a.KitsIssued, a.KitsRevoked,
            a.LastCompletedDrill?.CompletedAt, a.LastCompletedDrill?.ConfirmedMemberCount,
            a.LastCompletedDrill?.ResponseTime?.TotalSeconds, a.ArchiveLastSequence, a.ArchiveLastHash,
            generatedAt, hash);
    }

    public string ToText()
    {
        var sb = new StringBuilder();
        sb.AppendLine("Doklad o existenci a funkcnosti nouzoveho kanalu");
        sb.AppendLine($"Organizace: {Escape(OrganizationName)} ({OrganizationId})");
        sb.AppendLine($"Nouzova skupina existuje: {EmergencyGroupExists}");
        sb.AppendLine($"Auditor device: {AuditorDeviceId}");
        sb.AppendLine($"Pocet zapsanych zarizeni: {EnrolledMemberCount}");
        sb.AppendLine($"Vydane sady kodu: {KitsIssued} (zrusene: {KitsRevoked})");
        sb.AppendLine(LastDrillCompletedAt is null
            ? "Posledni cviceni: zadne dokoncene"
            : $"Posledni cviceni: {LastDrillCompletedAt:O}, potvrzeno {LastDrillConfirmedMemberCount}, doba odezvy {LastDrillResponseTimeSeconds}s");
        sb.AppendLine($"Archiv — posledni sekvence: {ArchiveLastSequence}, hash: {ArchiveLastHash}");
        sb.AppendLine($"Vygenerovano: {GeneratedAt:O}");
        sb.AppendLine($"SHA-256 dokladu: {SelfHashSha256}");
        return sb.ToString();
    }

    // Same formula-injection guard as OrganizationEndpoints.ToCsv/EscapeCsv —
    // this is plain text, not CSV, but the export can still be pasted into a
    // spreadsheet, so the same leading =+-@ prefix rule applies.
    private static string Escape(string value) =>
        value.Length > 0 && "=+-@".Contains(value[0]) ? "'" + value : value;
}
