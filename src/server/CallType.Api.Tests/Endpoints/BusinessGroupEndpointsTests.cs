// ---------------------------------------------------------------------------
// BusinessGroupEndpointsTests.cs — KB1 enforcement for business groups (E02)
// ---------------------------------------------------------------------------
// Docker/Testcontainers required (IntegrationTestBase) — not run on a
// machine without Docker; report BLOCKED there, not PASS.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Endpoints;

public class BusinessGroupEndpointsTests : IntegrationTestBase
{
    /// <summary>
    /// Connects an already-registered device to the hub via its own JWT — used
    /// to make the auditor "alive" for AuditorLivenessService (W2-F) in
    /// POST /groups/business tests. Caller starts and disposes it.
    /// </summary>
    private HubConnection ConnectHub(Guid deviceId, string token)
    {
        var server = Factory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={token}",
                options => options.HttpMessageHandlerFactory = _ => server.CreateHandler())
            .Build();
    }

    /// <summary>Creates an organization and, optionally, enrolls the given devices in it.</summary>
    private async Task<Guid> CreateOrganizationAsync(Guid? auditorDeviceId, params Guid[] enrolledDevices)
    {
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var now = DateTimeOffset.UtcNow;
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), now);
        org.AuditorDeviceId = auditorDeviceId;
        auditDb.Organizations.Add(org);

        foreach (var deviceId in enrolledDevices)
        {
            var invite = new OrgInvite(Guid.NewGuid(), org.OrganizationId, Guid.NewGuid().ToString(),
                Guid.NewGuid(), now, now.AddDays(1));
            auditDb.OrgInvites.Add(invite);
            auditDb.OrgEnrollments.Add(OrgEnrollment.Enroll(invite, deviceId, Guid.NewGuid(), now));
        }
        await auditDb.SaveChangesAsync();
        return org.OrganizationId;
    }

    [Fact]
    public async Task Business_group_creation_adds_the_auditor_as_a_member()
    {
        // Auditor is a real device (GroupMember.DeviceId is an FK to Devices).
        // Registered first: the helper leaves Client authenticated as the LAST
        // registered device, which must be the creator.
        var (auditor, auditorToken, _) = await RegisterAndAuthenticateAsync();
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(auditor, creator);

        // W2-F: POST /groups/business now fails closed on a dead auditor, so
        // the auditor must be connected for this creation to succeed.
        await using var auditing = ConnectHub(auditor, auditorToken);
        await auditing.StartAsync();
        var response = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });

        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var groupId = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();
        var members = await Client.GetFromJsonAsync<JsonElement>($"/groups/{groupId}/members");
        members.EnumerateArray().Should().ContainSingle(m =>
            m.GetProperty("deviceId").GetGuid() == auditor && m.GetProperty("role").GetString() == "auditor");
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Business_group_creation_without_auditor_configured_is_rejected()
    {
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(auditorDeviceId: null, creator);

        var response = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("auditor_not_configured");
    }

    [Fact]
    public async Task Business_group_creation_rejects_a_non_enrolled_member()
    {
        // Outsider first so the request is made by the enrolled creator — otherwise
        // the 403 would come from the caller being non-enrolled, not the member.
        var (outsider, _, _) = await RegisterAndAuthenticateAsync();
        // Auditor must be a real, connected device (W2-F fail-closed check
        // runs before the enrollment check) so this test isolates the
        // enrollment 403, not an auditor_unavailable 503.
        var (auditor, auditorToken, _) = await RegisterAndAuthenticateAsync();
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(auditor, creator); // outsider not enrolled

        await using var auditing = ConnectHub(auditor, auditorToken);
        await auditing.StartAsync();
        var response = await Client.PostAsJsonAsync("/groups/business",
            new { organizationId, memberDeviceIds = new[] { outsider } });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Auditor_cannot_be_removed_from_a_business_group()
    {
        // Auditor is a real device (GroupMember.DeviceId is an FK to Devices).
        // Registered first: the helper leaves Client authenticated as the LAST
        // registered device, which must be the creator.
        var (auditor, auditorToken, _) = await RegisterAndAuthenticateAsync();
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(auditor, creator);
        await using var auditing = ConnectHub(auditor, auditorToken);
        await auditing.StartAsync();
        var createResponse = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });
        var groupId = (await createResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var response = await Client.DeleteAsync($"/groups/{groupId}/members/{auditor}");

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("auditor_immutable");
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Adding_a_non_enrolled_device_to_a_business_group_is_rejected()
    {
        // Outsider first so Client stays authenticated as the creator (see above).
        var (outsider, _, _) = await RegisterAndAuthenticateAsync();
        var (auditor, auditorToken, _) = await RegisterAndAuthenticateAsync();
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(auditor, creator);
        await using var auditing = ConnectHub(auditor, auditorToken);
        await auditing.StartAsync();
        var createResponse = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });
        var groupId = (await createResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var response = await Client.PutAsJsonAsync($"/groups/{groupId}/members", new { deviceId = outsider });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        await auditing.StopAsync();
    }

    [Fact]
    public async Task Business_group_creation_is_rejected_with_503_when_the_auditor_is_dead()
    {
        // W2-F (f): a business conversation must not be CREATED while the
        // organization's auditor is dead = has not consumed its queue for longer
        // than the threshold (default 24 h). Merely being offline is fine.
        var (auditor, _, _) = await RegisterAndAuthenticateAsync();
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(auditor, creator);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<CallType.Api.Data.AppDbContext>();
            var stale = DateTimeOffset.UtcNow.AddDays(-2);
            db.QueuedMessages.Add(new CallType.Api.Models.QueuedMessage
            {
                MessageId = Guid.NewGuid(), GroupId = Guid.NewGuid(), RecipientId = auditor, SenderId = creator,
                EncryptedBody = [0x01], CreatedAt = stale, ExpiresAt = stale.AddDays(30)
            });
            await db.SaveChangesAsync();
        }

        var response = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("auditor_unavailable");
    }

    [Fact]
    public async Task Anonymous_group_creation_is_unaffected_by_business_mode_being_enabled()
    {
        // Guards against a regression where turning on business mode (Audit DB
        // configured in tests) accidentally changes the plain /groups path.
        var (member, _, _) = await RegisterAndAuthenticateAsync();
        var (creator, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { member } });

        response.StatusCode.Should().Be(HttpStatusCode.Created);
    }
}
