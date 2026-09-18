// ---------------------------------------------------------------------------
// OrganizationEndpoints.cs — Organization context API (plan §4, package E01)
// ---------------------------------------------------------------------------
// Business mode is entirely opt-in (BusinessModeOptions.Enabled) — every
// route here checks it first and returns 503 before touching AuditDbContext,
// which is only registered in DI when business mode is on (see Program.cs).
//
// Identity: the JWT identifies a device (same claim AccountEndpoints and
// GroupEndpoints use). Organization governance (owner/org-admin/etc.) is
// keyed by Account, not Device, so most mutating routes here additionally
// require the calling device to be linked to a registered Account (plan §3
// [PŘEDPOKLAD] 2) — enrollment (plain member, by invite) does not.
//
// All DomainRuleViolation codes are mapped to HTTP status once, in
// MapViolation, so the status<->code pairing lives in exactly one place.
// ---------------------------------------------------------------------------

using Microsoft.Extensions.DependencyInjection;
using System.Security.Claims;
using System.Text;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Audit.Domain;
using CallType.Audit.OrgManagement;

namespace CallType.Api.Endpoints;

public static class OrganizationEndpoints
{
    // Free-text fields (org name) feed into HashChain.Canonicalize, which
    // throws ArgumentException on U+001F/U+0000 — validate at the boundary
    // and return 422 instead of ever letting that surface as a 500.
    private const int MaxNameLength = 200;

    public static WebApplication MapOrganizationEndpoints(this WebApplication app)
    {
        app.MapPost("/orgs", CreateOrganization).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/mine", GetMine).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/orgs/enroll", Enroll).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{id:guid}", GetOrganization).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{id:guid}/enrollments", GetEnrollments).RequireAuthorization().RequireRateLimiting("api");
        app.MapPatch("/orgs/{id:guid}", UpdateOrganization).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/orgs/{id:guid}/members/{accountId:guid}", SetMemberRole).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/orgs/{id:guid}/members/{accountId:guid}", RemoveMember).RequireAuthorization().RequireRateLimiting("api");
        app.MapPost("/orgs/{id:guid}/invites", CreateInvite).RequireAuthorization().RequireRateLimiting("api");
        app.MapDelete("/orgs/{id:guid}/enrollments/{deviceId:guid}", RevokeEnrollment).RequireAuthorization().RequireRateLimiting("api");
        app.MapPut("/orgs/{id:guid}/auditor", SetAuditor).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{id:guid}/admin-audit", GetAdminAudit).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    // -----------------------------------------------------------------
    // POST /orgs
    // -----------------------------------------------------------------
    private static async Task<IResult> CreateOrganization(
        CreateOrganizationRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        if (!IsValidFreeText(request.Name, out var nameError)) return nameError;

        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();

        try
        {
            var organizationId = await service.CreateOrganizationAsync(accountId.Value, request.Name.Trim(), DateTimeOffset.UtcNow, ct);
            return Results.Created($"/orgs/{organizationId}", new { organizationId, name = request.Name.Trim() });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // GET /orgs/mine
    // -----------------------------------------------------------------
    private static async Task<IResult> GetMine(
        ClaimsPrincipal user, BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var deviceId = RequireDevice(user);
        if (deviceId is null) return Results.Unauthorized();

        var accountId = await LinkedAccountOrNullAsync(deviceId.Value, deliveryDb, ct);
        var orgs = await service.GetMyOrganizationsAsync(accountId, deviceId.Value, ct);
        return Results.Ok(orgs.Select(o => new
        {
            organizationId = o.OrganizationId, name = o.Name, role = o.Role.ToString(),
            archiveLevel = o.ArchiveLevel.ToString(), auditorDeviceId = o.AuditorDeviceId
        }));
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}
    // -----------------------------------------------------------------
    private static async Task<IResult> GetOrganization(
        Guid id, ClaimsPrincipal user, BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var deviceId = RequireDevice(user);
        if (deviceId is null) return Results.Unauthorized();
        var accountId = await LinkedAccountOrNullAsync(deviceId.Value, deliveryDb, ct);

        try
        {
            var org = await service.GetOrganizationAsync(id, accountId, deviceId.Value, ct);
            return Results.Ok(new
            {
                organizationId = org.OrganizationId, name = org.Name, createdAt = org.CreatedAt,
                archiveLevel = org.ArchiveLevel.ToString(), auditorDeviceId = org.AuditorDeviceId,
                members = org.Members.Select(m => new { accountId = m.AccountId, role = m.Role.ToString(), addedAt = m.AddedAt })
            });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/enrollments
    // -----------------------------------------------------------------
    private static async Task<IResult> GetEnrollments(
        Guid id, ClaimsPrincipal user, BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var deviceId = RequireDevice(user);
        if (deviceId is null) return Results.Unauthorized();
        var accountId = await LinkedAccountOrNullAsync(deviceId.Value, deliveryDb, ct);

        try
        {
            var enrollments = await service.GetEnrollmentsAsync(id, accountId, deviceId.Value, ct);
            return Results.Ok(enrollments.Select(e => new { deviceId = e.DeviceId, enrolledAt = e.EnrolledAt }));
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // PATCH /orgs/{id}
    // -----------------------------------------------------------------
    private static async Task<IResult> UpdateOrganization(
        Guid id, UpdateOrganizationRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        if (request.Name is not null && !IsValidFreeText(request.Name, out var nameError)) return nameError;
        ArchiveLevel? archiveLevel = null;
        if (request.ArchiveLevel is not null)
        {
            if (!Enum.TryParse<ArchiveLevel>(request.ArchiveLevel, true, out var parsed))
                return Results.BadRequest(new { error = "Invalid archiveLevel." });
            archiveLevel = parsed;
        }

        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, accountId.Value, user, clock, ct) is { } gate) return gate;

        try
        {
            await service.UpdateOrganizationAsync(id, accountId.Value, request.Name?.Trim(), archiveLevel, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // PUT /orgs/{id}/members/{accountId}
    // -----------------------------------------------------------------
    private static async Task<IResult> SetMemberRole(
        Guid id, Guid accountId, SetMemberRoleRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        if (!Enum.TryParse<OrgRole>(request.Role, true, out var role))
            return Results.BadRequest(new { error = "Invalid role." });

        var actorAccountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (actorAccountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, actorAccountId.Value, user, clock, ct) is { } gate) return gate;

        try
        {
            await service.SetMemberRoleAsync(id, actorAccountId.Value, accountId, role, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // DELETE /orgs/{id}/members/{accountId}
    // -----------------------------------------------------------------
    private static async Task<IResult> RemoveMember(
        Guid id, Guid accountId, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var actorAccountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (actorAccountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, actorAccountId.Value, user, clock, ct) is { } gate) return gate;

        try
        {
            await service.RemoveMemberAsync(id, actorAccountId.Value, accountId, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // POST /orgs/{id}/invites
    // -----------------------------------------------------------------
    private static async Task<IResult> CreateInvite(
        Guid id, CreateInviteRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, accountId.Value, user, clock, ct) is { } gate) return gate;

        // OrgInvite (frozen E00 domain) is single-use only — Redeem() sets
        // UsedAt on first enrollment. maxUses > 1 is not supported; reject
        // rather than silently accepting a promise we can't keep.
        if (request.MaxUses is > 1)
            return Results.UnprocessableEntity(new { error = "Multi-use invites are not supported.", code = "max_uses_unsupported" });

        try
        {
            var invite = await service.CreateInviteAsync(id, accountId.Value, request.ExpiresInHours, DateTimeOffset.UtcNow, ct);
            return Results.Ok(new { code = invite.Code, expiresAt = invite.ExpiresAt });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // POST /orgs/enroll
    // -----------------------------------------------------------------
    private static async Task<IResult> Enroll(
        EnrollRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var deviceId = RequireDevice(user);
        if (deviceId is null) return Results.Unauthorized();
        if (string.IsNullOrWhiteSpace(request.Code)) return Results.BadRequest(new { error = "Code is required." });

        var accountId = await LinkedAccountOrNullAsync(deviceId.Value, deliveryDb, ct);

        try
        {
            var organizationId = await service.EnrollAsync(request.Code, deviceId.Value, accountId, DateTimeOffset.UtcNow, ct);
            return Results.Ok(new { organizationId });
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // DELETE /orgs/{id}/enrollments/{deviceId}
    // -----------------------------------------------------------------
    private static async Task<IResult> RevokeEnrollment(
        Guid id, Guid deviceId, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, accountId.Value, user, clock, ct) is { } gate) return gate;

        try
        {
            await service.RevokeEnrollmentAsync(id, accountId.Value, deviceId, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // PUT /orgs/{id}/auditor
    // -----------------------------------------------------------------
    private static async Task<IResult> SetAuditor(
        Guid id, SetAuditorRequest request, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, accountId.Value, user, clock, ct) is { } gate) return gate;

        try
        {
            await service.SetAuditorDeviceAsync(id, accountId.Value, request.DeviceId, DateTimeOffset.UtcNow, ct);
            return Results.NoContent();
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // GET /orgs/{id}/admin-audit
    // -----------------------------------------------------------------
    private static async Task<IResult> GetAdminAudit(
        Guid id, DateTimeOffset? from, DateTimeOffset? to, string? format, ClaimsPrincipal user,
        BusinessModeOptions businessMode, AppDbContext deliveryDb, HttpContext http, TimeProvider clock, CancellationToken ct)
    {
        if (Gate503(businessMode) is { } disabled) return disabled;
        var service = http.RequestServices.GetRequiredService<OrganizationAppService>();
        var accountId = await RequireAccountAsync(user, deliveryDb, ct);
        if (accountId is null) return AccountRequired();
        if (await RequireOrgAdminThenStepUpAsync(service, id, accountId.Value, user, clock, ct) is { } gate) return gate;

        try
        {
            var events = await service.GetAdminAuditAsync(id, accountId.Value, from, to, ct);
            if (string.Equals(format, "csv", StringComparison.OrdinalIgnoreCase))
                return Results.Text(ToCsv(events), "text/csv");
            return Results.Ok(events.Select(e => new
            {
                sequence = e.Sequence, actorAccountId = e.ActorAccountId, eventType = e.EventType,
                details = e.DetailsJson, occurredAt = e.OccurredAt
            }));
        }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }
    }

    // -----------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------

    private static IResult? Gate503(BusinessModeOptions businessMode) => businessMode.Enabled
        ? null
        : Results.Json(new { error = "Business mode is not enabled on this server.", code = "business_mode_disabled" }, statusCode: StatusCodes.Status503ServiceUnavailable);

    private static Guid? RequireDevice(ClaimsPrincipal user) => AccountEndpoints.CallerDeviceId(user);

    /// <summary>
    /// N03b: gates every OrgAdmin+ mutation on MFA. Order matters for
    /// information leaks — membership/role is checked FIRST (via the same
    /// side-effect-free pre-check the mutating call itself runs), so a
    /// non-member still gets today's 404/403 and never mfa_required; only a
    /// confirmed org-admin without a fresh step-up token sees mfa_required.
    /// Returns null when the caller may proceed.
    /// </summary>
    private static async Task<IResult?> RequireOrgAdminThenStepUpAsync(
        OrganizationAppService service, Guid organizationId, Guid actorAccountId, ClaimsPrincipal user, TimeProvider clock, CancellationToken ct)
    {
        try { await service.EnsureOrgAdminAsync(organizationId, actorAccountId, ct); }
        catch (DomainRuleViolation ex) { return MapViolation(ex); }

        return MfaAuthHelper.RequireStepUp(user, actorAccountId, clock);
    }

    private static IResult AccountRequired() => Results.Json(
        new { error = "This action requires a registered account linked to the calling device.", code = "account_required" },
        statusCode: StatusCodes.Status403Forbidden);

    /// <summary>The calling device must be authenticated AND linked to a registered Account.</summary>
    private static async Task<Guid?> RequireAccountAsync(ClaimsPrincipal user, AppDbContext db, CancellationToken ct)
    {
        var deviceId = RequireDevice(user);
        if (deviceId is null) return null;
        return await LinkedAccountOrNullAsync(deviceId.Value, db, ct);
    }

    private static async Task<Guid?> LinkedAccountOrNullAsync(Guid deviceId, AppDbContext db, CancellationToken ct) =>
        await db.AccountDevices.Where(ad => ad.DeviceId == deviceId).Select(ad => (Guid?)ad.AccountId).FirstOrDefaultAsync(ct);

    private static bool IsValidFreeText(string value, out IResult error)
    {
        error = Results.UnprocessableEntity(new { error = "Invalid text field.", code = "invalid_free_text" });
        if (string.IsNullOrWhiteSpace(value) || value.Length > MaxNameLength) return false;
        // HashChain.Canonicalize throws on these — reject here so the failure
        // is a clean 422, not an unhandled exception surfacing as a 500.
        return !value.Contains('') && !value.Contains('\0');
    }

    private static IResult MapViolation(DomainRuleViolation ex) => ex.Code switch
    {
        "org_not_found" or "member_not_found" => Results.NotFound(new { error = ex.Message, code = ex.Code }),
        "forbidden" => Results.Json(new { error = ex.Message, code = ex.Code }, statusCode: StatusCodes.Status403Forbidden),
        "invite_invalid" => Results.Json(new { error = ex.Message, code = ex.Code }, statusCode: StatusCodes.Status410Gone),
        "auditor_device_invalid" => Results.UnprocessableEntity(new { error = ex.Message, code = ex.Code }),
        _ => Results.Conflict(new { error = ex.Message, code = ex.Code }) // org_limit, already_member, multiple_owners, last_owner, last_admin, owner_transfer_unsupported
    };

    /// <summary>
    /// CSV export for GET .../admin-audit?format=csv. Every cell that could
    /// be interpreted as a spreadsheet formula (leading =, +, -, @) is
    /// prefixed with a literal quote so Excel/Sheets renders it as text
    /// instead of executing it (CSV formula injection).
    /// </summary>
    internal static string ToCsv(IReadOnlyList<AdminAuditEventDto> events)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Sequence,ActorAccountId,EventType,OccurredAt,Details");
        foreach (var e in events)
        {
            sb.Append(e.Sequence).Append(',')
              .Append(EscapeCsv(e.ActorAccountId.ToString())).Append(',')
              .Append(EscapeCsv(e.EventType)).Append(',')
              .Append(EscapeCsv(e.OccurredAt.ToString("O"))).Append(',')
              .Append(EscapeCsv(e.DetailsJson))
              .Append('\n');
        }
        return sb.ToString();
    }

    private static string EscapeCsv(string value)
    {
        if (value.Length > 0 && (value[0] == '=' || value[0] == '+' || value[0] == '-' || value[0] == '@'))
            value = "'" + value;
        var quoted = value.Replace("\"", "\"\"");
        return $"\"{quoted}\"";
    }
}

// ---------------------------------------------------------------------------
// Request DTOs
// ---------------------------------------------------------------------------

public record CreateOrganizationRequest(string Name);
public record UpdateOrganizationRequest(string? Name, string? ArchiveLevel);
public record SetMemberRoleRequest(string Role);
public record CreateInviteRequest(int? ExpiresInHours, int? MaxUses);
public record EnrollRequest(string Code);
public record SetAuditorRequest(Guid DeviceId);
