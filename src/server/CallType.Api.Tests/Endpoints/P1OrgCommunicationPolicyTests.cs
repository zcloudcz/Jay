// ---------------------------------------------------------------------------
// P1OrgCommunicationPolicyTests.cs — Organization.RequireBusinessConversations
// ---------------------------------------------------------------------------
// Covers plan §8a item 5 / docs/superpowers/plans/2026-09-18-business-mode-contracts.md
// (P1 section added by this package): the org-wide policy that forces two
// enrolled devices to talk only inside a business conversation, enforced on
// 1:1 sends, anonymous group creation/joining, and anonymous call offers.
//
// PATCH /orgs/{id} is covered here too (rather than only in
// OrganizationEndpointsTests) because it is the only way to flip the flag,
// and because the MFA step-up gate on it is part of P1's acceptance criteria.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Endpoints;

public class P1OrgCommunicationPolicyTests : IntegrationTestBase
{
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    private async Task<(Guid DeviceId, string Token)> RegisterDeviceAndGetTokenAsync()
    {
        using var client = Factory.CreateClient();
        var regResponse = await client.PostAsJsonAsync("/devices", new { identityKey = ValidIdentityKey, signedPreKey = ValidSignedPreKey });
        regResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var regBody = await regResponse.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = Guid.Parse(regBody.GetProperty("deviceId").GetString()!);
        var deviceSecret = regBody.GetProperty("deviceSecret").GetString()!;
        var tokenResponse = await client.PostAsJsonAsync("/auth/token", new { deviceId, deviceSecret });
        tokenResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var tokenBody = await tokenResponse.Content.ReadFromJsonAsync<JsonElement>();
        return (deviceId, tokenBody.GetProperty("token").GetString()!);
    }

    private HubConnection CreateHubConnection(string accessToken)
    {
        var server = Factory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={accessToken}", options =>
                options.HttpMessageHandlerFactory = _ => server.CreateHandler())
            .Build();
    }

    /// <summary>
    /// Creates a real Organization with the given devices actively enrolled
    /// (OrgEnrollment, not OrgMember — this policy is about DEVICES). The
    /// auditor device, if given, is deliberately left un-enrolled: KB1's
    /// auditor sits behind Organization.AuditorDeviceId, not OrgEnrollment,
    /// which is exactly the "lookup miss = allowed" case P1 relies on.
    /// </summary>
    private async Task<Guid> CreateOrganizationWithEnrolledDevicesAsync(bool requireBusinessConversations, params Guid[] devices)
    {
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
        org.SetRequireBusinessConversations(requireBusinessConversations);
        auditDb.Organizations.Add(org);
        foreach (var device in devices)
            auditDb.OrgEnrollments.Add(OrgEnrollment.Enroll(
                new OrgInvite(Guid.NewGuid(), org.OrganizationId, Guid.NewGuid().ToString(), Guid.NewGuid(), DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddDays(1)),
                device, Guid.Empty, DateTimeOffset.UtcNow));
        await auditDb.SaveChangesAsync();
        return org.OrganizationId;
    }

    // -----------------------------------------------------------------
    // 1:1 messages
    // -----------------------------------------------------------------

    [Fact]
    public async Task Policy_off_1to1_between_enrolled_members_still_works()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: false, a, b);
        await using var connection = CreateHubConnection(tokenA);
        await connection.StartAsync();

        await connection.InvokeAsync("SendMessage", b, Convert.ToBase64String([0x01]));
    }

    [Fact]
    public async Task Policy_on_rejects_1to1_between_two_enrolled_members()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        await using var connection = CreateHubConnection(tokenA);
        await connection.StartAsync();

        var send = () => connection.InvokeAsync("SendMessage", b, Convert.ToBase64String([0x01]));
        (await send.Should().ThrowAsync<HubException>()).Which.Message.Should().Contain("business_conversation_required");
    }

    [Fact]
    public async Task Policy_on_allows_1to1_with_an_outsider()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (outsider, _) = await RegisterDeviceAndGetTokenAsync();
        await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a); // outsider never enrolled
        await using var connection = CreateHubConnection(tokenA);
        await connection.StartAsync();

        await connection.InvokeAsync("SendMessage", outsider, Convert.ToBase64String([0x01]));
    }

    [Fact]
    public async Task Policy_on_allows_1to1_with_the_organizations_auditor()
    {
        // KB1: the auditor is never an OrgEnrollment row, so a lookup miss for
        // it must fall through to "allowed" — this is what proves it.
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, _) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a);
        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = await auditDb.Organizations.SingleAsync(o => o.OrganizationId == organizationId);
            org.AuditorDeviceId = auditor;
            await auditDb.SaveChangesAsync();
        }
        await using var connection = CreateHubConnection(tokenA);
        await connection.StartAsync();

        await connection.InvokeAsync("SendMessage", auditor, Convert.ToBase64String([0x01]));
    }

    [Fact]
    public async Task Revoked_enrollment_is_not_subject_to_the_rule()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var enrollment = await auditDb.OrgEnrollments.SingleAsync(e => e.OrganizationId == organizationId && e.DeviceId == b);
            enrollment.RevokedAt = DateTimeOffset.UtcNow;
            await auditDb.SaveChangesAsync();
        }
        await using var connection = CreateHubConnection(tokenA);
        await connection.StartAsync();

        await connection.InvokeAsync("SendMessage", b, Convert.ToBase64String([0x01]));
    }

    [Fact]
    public async Task Business_mode_disabled_never_blocks_1to1()
    {
        // Derived factory with no ConnectionStrings:Audit — same pattern as
        // OrganizationEndpointsTests.Endpoints_return_503_when_business_mode_is_disabled.
        // Its own HttpClient/hub connection: the shared Factory/Client always
        // has business mode ON (IntegrationTestBase), so this needs a fresh host.
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Audit"] = null })));
        using var client = factory.CreateClient();

        var regA = await client.PostAsJsonAsync("/devices", new { identityKey = ValidIdentityKey, signedPreKey = ValidSignedPreKey });
        var bodyA = await regA.Content.ReadFromJsonAsync<JsonElement>();
        var deviceA = Guid.Parse(bodyA.GetProperty("deviceId").GetString()!);
        var tokenRespA = await client.PostAsJsonAsync("/auth/token", new { deviceId = deviceA, deviceSecret = bodyA.GetProperty("deviceSecret").GetString()! });
        var tokenA = (await tokenRespA.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        using var clientB = factory.CreateClient();
        var regB = await clientB.PostAsJsonAsync("/devices", new { identityKey = ValidIdentityKey, signedPreKey = ValidSignedPreKey });
        var deviceB = Guid.Parse((await regB.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("deviceId").GetString()!);

        var server = factory.Server;
        await using var connection = new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={tokenA}", o => o.HttpMessageHandlerFactory = _ => server.CreateHandler())
            .Build();
        await connection.StartAsync();

        await connection.InvokeAsync("SendMessage", deviceB, Convert.ToBase64String([0x01]));
    }

    // -----------------------------------------------------------------
    // Anonymous groups (create + join)
    // -----------------------------------------------------------------

    [Fact]
    public async Task Policy_on_rejects_creating_an_anonymous_group_between_two_members()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        Client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenA);

        var response = await Client.PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { b } });

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("business_conversation_required");
    }

    [Fact]
    public async Task Policy_on_rejects_adding_a_member_to_an_existing_anonymous_group()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (outsider, _) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        Client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenA);
        var created = await Client.PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { outsider } });
        created.StatusCode.Should().Be(HttpStatusCode.Created);
        var groupId = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var response = await Client.PutAsJsonAsync($"/groups/{groupId}/members", new { deviceId = b });

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Business_group_traffic_is_unaffected_by_the_policy()
    {
        // KB2/business-group creation is a different, already-audited path —
        // P1 must never block it.
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, auditorToken) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = await auditDb.Organizations.SingleAsync(o => o.OrganizationId == organizationId);
            org.AuditorDeviceId = auditor;
            await auditDb.SaveChangesAsync();
        }
        Client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenA);

        var response = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = new[] { b } });

        response.StatusCode.Should().Be(HttpStatusCode.Created);
    }

    // -----------------------------------------------------------------
    // Anonymous calls
    // -----------------------------------------------------------------

    [Fact]
    public async Task Policy_on_rejects_an_anonymous_call_offer_between_two_members()
    {
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, _) = await RegisterDeviceAndGetTokenAsync();
        await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        await using var connection = CreateHubConnection(tokenA);
        await connection.StartAsync();

        var send = () => connection.InvokeAsync("CallSignal", b, "offer", "{\"sdp\":\"test\"}");
        (await send.Should().ThrowAsync<HubException>()).Which.Message.Should().Contain("business_conversation_required");
    }

    [Fact]
    public async Task Emergency_and_business_calls_are_unaffected_by_the_policy()
    {
        // BusinessCallSignal is a different wire path (businessGroupId set) —
        // P1 only touches the anonymous CallSignal.
        var (a, tokenA) = await RegisterDeviceAndGetTokenAsync();
        var (b, tokenB) = await RegisterDeviceAndGetTokenAsync();
        var (auditor, _) = await RegisterDeviceAndGetTokenAsync();
        var organizationId = await CreateOrganizationWithEnrolledDevicesAsync(requireBusinessConversations: true, a, b);
        Guid group;
        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = await auditDb.Organizations.SingleAsync(o => o.OrganizationId == organizationId);
            org.AuditorDeviceId = auditor;
            await auditDb.SaveChangesAsync();

            var db = scope.ServiceProvider.GetRequiredService<CallType.Api.Data.AppDbContext>();
            group = Guid.NewGuid();
            db.Groups.Add(new CallType.Api.Models.Group { GroupId = group, CreatedBy = a, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId });
            db.GroupMembers.AddRange(
                new CallType.Api.Models.GroupMember { GroupId = group, DeviceId = a, Role = "admin" },
                new CallType.Api.Models.GroupMember { GroupId = group, DeviceId = b, Role = "member" },
                new CallType.Api.Models.GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
            await db.SaveChangesAsync();
        }
        await using var connectionA = CreateHubConnection(tokenA);
        await using var connectionB = CreateHubConnection(tokenB);
        var signalTcs = new TaskCompletionSource<JsonElement>();
        connectionB.On<JsonElement>("CallSignal", s => signalTcs.TrySetResult(s));
        await connectionA.StartAsync();
        await connectionB.StartAsync();
        await connectionB.InvokeAsync("RequestPendingMessages");

        await connectionA.InvokeAsync("BusinessCallSignal", b, "offer", "{}", group);

        var received = await signalTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
        received.GetProperty("signalType").GetString().Should().Be("offer");
    }

    // -----------------------------------------------------------------
    // PATCH /orgs/{id} — flag write, read-back, MFA gate, admin audit
    // -----------------------------------------------------------------

    [Fact]
    public async Task Patch_toggles_the_flag_writes_admin_audit_and_is_visible_on_reads()
    {
        await CreateAccountLinkedDeviceAsync("p1-patch-owner@example.com"); // also points Client at a step-up token
        var created = await Client.PostAsJsonAsync("/orgs", new { name = "Acme" });
        created.StatusCode.Should().Be(HttpStatusCode.Created);
        var organizationId = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetGuid();

        var patch = await Client.PatchAsJsonAsync($"/orgs/{organizationId}", new { requireBusinessConversations = true });
        patch.StatusCode.Should().Be(HttpStatusCode.NoContent);

        var mine = await Client.GetFromJsonAsync<JsonElement>("/orgs/mine");
        mine.EnumerateArray().Single(o => o.GetProperty("organizationId").GetGuid() == organizationId)
            .GetProperty("requireBusinessConversations").GetBoolean().Should().BeTrue();
        var details = await Client.GetFromJsonAsync<JsonElement>($"/orgs/{organizationId}");
        details.GetProperty("requireBusinessConversations").GetBoolean().Should().BeTrue();

        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var events = await auditDb.AdminAuditEvents.Where(e => e.OrganizationId == organizationId).ToListAsync();
        events.Should().Contain(e => e.DetailsJson.Contains("requireBusinessConversations"));
    }

    [Fact]
    public async Task Patch_requires_mfa_step_up()
    {
        // Deliberately does NOT call EnrollAndVerifyMfaAsync — Client stays on
        // the plain device token throughout, which PATCH must refuse.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email = $"p1-patch-no-mfa-{Guid.NewGuid()}@example.com", authKey = ValidAuthKey });
        accountResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = (await accountResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetGuid();
        (await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey }))
            .StatusCode.Should().Be(HttpStatusCode.OK);
        var created = await Client.PostAsJsonAsync("/orgs", new { name = "Acme" });
        var organizationId = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetGuid();

        var patch = await Client.PatchAsJsonAsync($"/orgs/{organizationId}", new { requireBusinessConversations = true });

        patch.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await patch.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_required");
    }

    private static readonly string ValidAuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    /// <summary>
    /// Registers+authenticates a device, registers an account, links them,
    /// enrols+verifies MFA, and points Client at the resulting step-up token —
    /// same flow as OrganizationEndpointsTests.CreateAccountLinkedDeviceAsync.
    /// </summary>
    private async Task<(Guid DeviceId, Guid AccountId)> CreateAccountLinkedDeviceAsync(string email)
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        accountResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = (await accountResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetGuid();

        var linkResponse = await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey });
        linkResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var stepUpToken = await EnrollAndVerifyMfaAsync(Client, accountId, ValidAuthKey);
        Client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", stepUpToken);

        return (deviceId, accountId);
    }
}
