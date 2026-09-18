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
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Endpoints;

public class BusinessGroupEndpointsTests : IntegrationTestBase
{
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
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var auditor = Guid.NewGuid();
        var organizationId = await CreateOrganizationAsync(auditor, creator);

        var response = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });

        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var groupId = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();
        var members = await Client.GetFromJsonAsync<JsonElement>($"/groups/{groupId}/members");
        members.EnumerateArray().Should().ContainSingle(m =>
            m.GetProperty("deviceId").GetGuid() == auditor && m.GetProperty("role").GetString() == "auditor");
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
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var (outsider, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(Guid.NewGuid(), creator); // outsider not enrolled

        var response = await Client.PostAsJsonAsync("/groups/business",
            new { organizationId, memberDeviceIds = new[] { outsider } });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Auditor_cannot_be_removed_from_a_business_group()
    {
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var auditor = Guid.NewGuid();
        var organizationId = await CreateOrganizationAsync(auditor, creator);
        var createResponse = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });
        var groupId = (await createResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var response = await Client.DeleteAsync($"/groups/{groupId}/members/{auditor}");

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("auditor_immutable");
    }

    [Fact]
    public async Task Adding_a_non_enrolled_device_to_a_business_group_is_rejected()
    {
        var (creator, _, _) = await RegisterAndAuthenticateAsync();
        var (outsider, _, _) = await RegisterAndAuthenticateAsync();
        var organizationId = await CreateOrganizationAsync(Guid.NewGuid(), creator);
        var createResponse = await Client.PostAsJsonAsync("/groups/business", new { organizationId, memberDeviceIds = Array.Empty<Guid>() });
        var groupId = (await createResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var response = await Client.PutAsJsonAsync($"/groups/{groupId}/members", new { deviceId = outsider });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
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
