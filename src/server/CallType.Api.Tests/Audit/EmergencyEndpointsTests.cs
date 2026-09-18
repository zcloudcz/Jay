// ---------------------------------------------------------------------------
// EmergencyEndpointsTests.cs — E07: emergency kits, offline enrollment, drills
// ---------------------------------------------------------------------------
// Covers: kit issue stores hashes only (never the plaintext code), enroll
// creates an OrgEnrollment and joins the org's emergency group alongside its
// auditor, code reuse -> 410 emergency_code_used, a revoked kit's remaining
// codes -> 410 kit_revoked, the drill start/confirm/complete lifecycle and
// its counts, the proof export's reproducible hash and its formula-injection
// escaping, and that every mutation writes an AdminAuditEvent (KB6).
//
// BLOCKED on this machine: Testcontainers needs Docker, which is not
// installed here (see BusinessModeIntegrationTests for the same note). This
// file compiles and is believed correct but has not been executed.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Audit;

public class EmergencyEndpointsTests : IntegrationTestBase
{
    /// <summary>
    /// Seeds an organization whose Owner account is linked to
    /// <paramref name="adminDeviceId"/> (so that device can call OrgAdmin+
    /// endpoints) and whose auditor is a plain, unregistered device id — the
    /// emergency endpoints never call IDeliveryDirectory.IsBotDeviceAsync
    /// (only PUT /orgs/{id}/auditor does, via E01), so no real Device row is
    /// needed for it.
    /// </summary>
    private async Task<(Guid OrgId, Guid AuditorDeviceId)> SeedOrgWithAdminAsync(Guid adminDeviceId)
    {
        var orgId = Guid.NewGuid();
        // The auditor must be a real registered device (GroupMember.DeviceId is an FK
        // to Devices). Registering re-points Client's Bearer token, so restore the
        // caller's (admin's) header afterwards.
        var callerAuth = Client.DefaultRequestHeaders.Authorization;
        var (auditorDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        Client.DefaultRequestHeaders.Authorization = callerAuth;
        var ownerAccountId = Guid.NewGuid();

        using var scope = Factory.Services.CreateScope();
        var appDb = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();

        var org = Organization.Create(orgId, "Acme", ownerAccountId, DateTimeOffset.UtcNow);
        org.AuditorDeviceId = auditorDeviceId;
        auditDb.Organizations.Add(org);
        await auditDb.SaveChangesAsync();

        appDb.Accounts.Add(new Account { AccountId = ownerAccountId, Email = $"{ownerAccountId}@acme.test", CreatedAt = DateTimeOffset.UtcNow });
        appDb.AccountDevices.Add(new AccountDevice { AccountId = ownerAccountId, DeviceId = adminDeviceId, LinkedAt = DateTimeOffset.UtcNow });
        await appDb.SaveChangesAsync();

        return (orgId, auditorDeviceId);
    }

    private void UseToken(string token) =>
        Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

    [Fact]
    public async Task Issuing_a_kit_without_an_auditor_is_rejected_and_stores_nothing()
    {
        // Found by the live E2E run: the 409 used to come AFTER the kit had been
        // written, leaving an orphan kit (codes nobody ever saw) in the
        // append-only audit database and in the proof export.
        var (adminDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        var (orgId, _) = await SeedOrgWithAdminAsync(adminDeviceId);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            (await db.Organizations.SingleAsync(o => o.OrganizationId == orgId)).AuditorDeviceId = null;
            await db.SaveChangesAsync();
        }

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/emergency/kits", new { label = "too early", count = 2 });

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("auditor_not_configured");
        using var verify = Factory.Services.CreateScope();
        var auditDb = verify.ServiceProvider.GetRequiredService<AuditDbContext>();
        (await auditDb.EmergencyKits.AnyAsync(k => k.OrganizationId == orgId)).Should().BeFalse();
        (await auditDb.EmergencyEnrollmentCodes.AnyAsync(c => c.OrganizationId == orgId)).Should().BeFalse();
    }

    [Fact]
    public async Task Issuing_a_kit_stores_only_hashes_never_the_plaintext_codes()
    {
        var (adminDeviceId, adminToken, _) = await RegisterAndAuthenticateAsync();
        var (orgId, _) = await SeedOrgWithAdminAsync(adminDeviceId);

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/emergency/kits",
            new { label = "HQ incident team", count = 3 });

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var codes = body.GetProperty("codes").EnumerateArray().Select(e => e.GetString()!).ToList();
        codes.Should().HaveCount(3);

        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var storedHashes = await auditDb.EmergencyEnrollmentCodes
            .Where(c => c.OrganizationId == orgId).Select(c => c.CodeHash).ToListAsync();

        storedHashes.Should().HaveCount(3);
        // The plaintext codes must never appear anywhere in the stored hashes.
        foreach (var code in codes)
            storedHashes.Should().NotContain(code);

        var kit = await auditDb.EmergencyKits.SingleAsync(k => k.OrganizationId == orgId);
        kit.Label.Should().Be("HQ incident team");
        kit.RecoveryCodeHash.Should().NotBe(body.GetProperty("recoveryCode").GetString());

        var events = await auditDb.AdminAuditEvents.Where(e => e.OrganizationId == orgId).ToListAsync();
        events.Should().Contain(e => e.EventType == "emergency_kit_issued");

        // KB1: issuing the first kit must create the org's emergency group with the auditor.
        var appDb = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var group = await appDb.Groups.SingleAsync(g => g.OrganizationId == orgId && g.IsEmergencyChannel);
        (await appDb.GroupMembers.CountAsync(m => m.GroupId == group.GroupId && m.Role == "auditor")).Should().Be(1);
    }

    [Fact]
    public async Task Enrolling_joins_the_emergency_group_alongside_the_auditor()
    {
        var (adminDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        var (orgId, auditorDeviceId) = await SeedOrgWithAdminAsync(adminDeviceId);
        var issueResponse = await Client.PostAsJsonAsync($"/orgs/{orgId}/emergency/kits", new { label = "Kit", count = 1 });
        var code = (await issueResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("codes")[0].GetString()!;

        var (memberDeviceId, _, _) = await RegisterAndAuthenticateAsync(); // switches Client's bearer to this new device

        var enrollResponse = await Client.PostAsJsonAsync("/orgs/emergency/enroll", new { code });

        enrollResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var enrolled = await enrollResponse.Content.ReadFromJsonAsync<JsonElement>();
        enrolled.GetProperty("organizationId").GetGuid().Should().Be(orgId);

        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        (await auditDb.OrgEnrollments.SingleOrDefaultAsync(
            e => e.OrganizationId == orgId && e.DeviceId == memberDeviceId && e.RevokedAt == null))
            .Should().NotBeNull();

        var appDb = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var group = await appDb.Groups.SingleAsync(g => g.OrganizationId == orgId && g.IsEmergencyChannel);

        // groupId lets the client open the emergency conversation right after
        // enrolling instead of landing on the chat list (docs/acceptance/business-mode.md).
        enrolled.GetProperty("groupId").GetGuid().Should().Be(group.GroupId);

        var memberRoles = await appDb.GroupMembers.Where(m => m.GroupId == group.GroupId)
            .Select(m => new { m.DeviceId, m.Role }).ToListAsync();
        memberRoles.Should().Contain(m => m.DeviceId == memberDeviceId && m.Role == "member");
        memberRoles.Should().Contain(m => m.DeviceId == auditorDeviceId && m.Role == "auditor");
    }

    [Fact]
    public async Task Reusing_an_emergency_code_returns_410_emergency_code_used()
    {
        var (adminDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        var (orgId, _) = await SeedOrgWithAdminAsync(adminDeviceId);
        var issueResponse = await Client.PostAsJsonAsync($"/orgs/{orgId}/emergency/kits", new { label = "Kit", count = 1 });
        var code = (await issueResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("codes")[0].GetString()!;

        await RegisterAndAuthenticateAsync();
        var first = await Client.PostAsJsonAsync("/orgs/emergency/enroll", new { code });
        first.StatusCode.Should().Be(HttpStatusCode.OK);

        await RegisterAndAuthenticateAsync(); // a second device tries the same code
        var second = await Client.PostAsJsonAsync("/orgs/emergency/enroll", new { code });

        second.StatusCode.Should().Be(HttpStatusCode.Gone);
        var body = await second.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("code").GetString().Should().Be("emergency_code_used");
    }

    [Fact]
    public async Task A_revoked_kits_remaining_codes_return_410_kit_revoked()
    {
        var (adminDeviceId, adminToken, _) = await RegisterAndAuthenticateAsync();
        var (orgId, _) = await SeedOrgWithAdminAsync(adminDeviceId);
        var issueResponse = await Client.PostAsJsonAsync($"/orgs/{orgId}/emergency/kits", new { label = "Kit", count = 2 });
        var issued = await issueResponse.Content.ReadFromJsonAsync<JsonElement>();
        var kitId = issued.GetProperty("kitId").GetString();
        var unusedCode = issued.GetProperty("codes")[1].GetString()!;

        var revokeResponse = await Client.DeleteAsync($"/orgs/{orgId}/emergency/kits/{kitId}");
        revokeResponse.StatusCode.Should().Be(HttpStatusCode.NoContent);

        await RegisterAndAuthenticateAsync();
        var enrollResponse = await Client.PostAsJsonAsync("/orgs/emergency/enroll", new { code = unusedCode });

        enrollResponse.StatusCode.Should().Be(HttpStatusCode.Gone);
        var body = await enrollResponse.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("code").GetString().Should().Be("kit_revoked");

        UseToken(adminToken);
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var events = await auditDb.AdminAuditEvents.Where(e => e.OrganizationId == orgId).ToListAsync();
        events.Should().Contain(e => e.EventType == "emergency_kit_revoked");
    }

    [Fact]
    public async Task Drill_lifecycle_counts_confirmations_and_records_response_time()
    {
        var (adminDeviceId, adminToken, _) = await RegisterAndAuthenticateAsync();
        var (orgId, _) = await SeedOrgWithAdminAsync(adminDeviceId);
        var issueResponse = await Client.PostAsJsonAsync($"/orgs/{orgId}/emergency/kits", new { label = "Kit", count = 1 });
        var code = (await issueResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("codes")[0].GetString()!;

        await RegisterAndAuthenticateAsync();
        await Client.PostAsJsonAsync("/orgs/emergency/enroll", new { code });
        var memberToken = Client.DefaultRequestHeaders.Authorization!.Parameter!;

        UseToken(adminToken);
        var startResponse = await Client.PostAsync($"/orgs/{orgId}/emergency/drills", null);
        startResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var drillId = (await startResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("drillId").GetInt64();

        UseToken(memberToken);
        var confirmResponse = await Client.PostAsync($"/orgs/{orgId}/emergency/drills/{drillId}/confirm", null);
        confirmResponse.StatusCode.Should().Be(HttpStatusCode.NoContent);

        // A second confirm from the same device must not double-count.
        await Client.PostAsync($"/orgs/{orgId}/emergency/drills/{drillId}/confirm", null);

        UseToken(adminToken);
        var completeResponse = await Client.PostAsync($"/orgs/{orgId}/emergency/drills/{drillId}/complete", null);
        completeResponse.StatusCode.Should().Be(HttpStatusCode.NoContent);

        var listResponse = await Client.GetAsync($"/orgs/{orgId}/emergency/drills");
        var drills = await listResponse.Content.ReadFromJsonAsync<JsonElement>();
        var drill = drills.EnumerateArray().Single();
        drill.GetProperty("confirmedMemberCount").GetInt32().Should().Be(1);
        drill.GetProperty("responseTimeSeconds").GetDouble().Should().BeGreaterThanOrEqualTo(0);

        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var events = await auditDb.AdminAuditEvents.Where(e => e.OrganizationId == orgId).ToListAsync();
        events.Should().Contain(e => e.EventType == "emergency_drill_started");
        events.Should().Contain(e => e.EventType == "emergency_drill_completed");
    }

    [Fact]
    public async Task Proof_export_hash_is_reproducible_and_escapes_formula_looking_names()
    {
        var (adminDeviceId, adminToken, _) = await RegisterAndAuthenticateAsync();
        var (orgId, _) = await SeedOrgWithAdminAsync(adminDeviceId);

        // Rename the org to something that looks like a spreadsheet formula —
        // the txt export must neutralize it (same rule as OrganizationEndpoints.EscapeCsv).
        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = await auditDb.Organizations.SingleAsync(o => o.OrganizationId == orgId);
            org.Rename("=SUM(A1:A9)");
            await auditDb.SaveChangesAsync();
        }

        var first = await Client.GetAsync($"/orgs/{orgId}/emergency/proof?format=json");
        var second = await Client.GetAsync($"/orgs/{orgId}/emergency/proof?format=json");
        first.StatusCode.Should().Be(HttpStatusCode.OK);

        var firstBody = await first.Content.ReadFromJsonAsync<JsonElement>();
        var secondBody = await second.Content.ReadFromJsonAsync<JsonElement>();
        // Same underlying data, two separate requests (necessarily different
        // GeneratedAt) — the hash must still match (excludes GeneratedAt).
        firstBody.GetProperty("selfHashSha256").GetString()
            .Should().Be(secondBody.GetProperty("selfHashSha256").GetString());

        var txtResponse = await Client.GetAsync($"/orgs/{orgId}/emergency/proof?format=txt");
        var txt = await txtResponse.Content.ReadAsStringAsync();
        txt.Should().Contain("'=SUM(A1:A9)");
    }
}
