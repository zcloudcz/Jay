// ---------------------------------------------------------------------------
// OrganizationEndpointsTests.cs — Integration tests for the Organization
// context API (plan §4, package E01)
// ---------------------------------------------------------------------------
// BLOCKED on this machine: Testcontainers needs Docker, which is not
// installed here. These tests compile and are believed correct, but have
// not been executed — see the E01 final report.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class OrganizationEndpointsTests : IntegrationTestBase
{
    private static readonly string ValidAuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    /// <summary>
    /// Registers+authenticates a device, registers an account, and links the
    /// two — the "OrgAdmin+ endpoints require a registered account" flow
    /// almost every test here needs before it can call POST /orgs.
    /// </summary>
    private async Task<(Guid DeviceId, Guid AccountId)> CreateAccountLinkedDeviceAsync(string email)
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        accountResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = Guid.Parse((await accountResponse.Content.ReadFromJsonAsync<JsonElement>())
            .GetProperty("accountId").GetString()!);

        var linkResponse = await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey });
        linkResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        return (deviceId, accountId);
    }

    private async Task<Guid> CreateOrganizationAsync(string name)
    {
        var response = await Client.PostAsJsonAsync("/orgs", new { name });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        return Guid.Parse((await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetString()!);
    }

    // -----------------------------------------------------------------
    // POST /orgs
    // -----------------------------------------------------------------

    [Fact]
    public async Task Create_requires_a_registered_account_linked_to_the_device()
    {
        await RegisterAndAuthenticateAsync(); // device only, no account
        var response = await Client.PostAsJsonAsync("/orgs", new { name = "Acme" });
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Create_makes_the_caller_the_sole_owner_and_a_second_org_is_rejected()
    {
        await CreateAccountLinkedDeviceAsync("owner@example.com");

        var first = await Client.PostAsJsonAsync("/orgs", new { name = "Acme" });
        first.StatusCode.Should().Be(HttpStatusCode.Created);

        var second = await Client.PostAsJsonAsync("/orgs", new { name = "Acme 2" });
        second.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await second.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("org_limit");
    }

    [Fact]
    public async Task Create_rejects_a_name_containing_the_hash_chain_separator()
    {
        await CreateAccountLinkedDeviceAsync("owner2@example.com");
        var response = await Client.PostAsJsonAsync("/orgs", new { name = "AcmeInc" });
        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    // -----------------------------------------------------------------
    // GET /orgs/mine, GET /orgs/{id}
    // -----------------------------------------------------------------

    [Fact]
    public async Task Mine_lists_organizations_the_caller_owns()
    {
        await CreateAccountLinkedDeviceAsync("mine@example.com");
        var orgId = await CreateOrganizationAsync("Acme");

        var mine = await Client.GetFromJsonAsync<JsonElement>("/orgs/mine");
        mine.EnumerateArray().Should().ContainSingle(o =>
            o.GetProperty("organizationId").GetGuid() == orgId && o.GetProperty("role").GetString() == "Owner");
    }

    [Fact]
    public async Task Get_by_id_hides_existence_from_non_members()
    {
        await CreateAccountLinkedDeviceAsync("owner3@example.com");
        var orgId = await CreateOrganizationAsync("Acme");

        await RegisterAndAuthenticateAsync(); // an unrelated device
        var response = await Client.GetAsync($"/orgs/{orgId}");
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    // -----------------------------------------------------------------
    // PUT/DELETE /orgs/{id}/members/{accountId} — invariants
    // -----------------------------------------------------------------

    [Fact]
    public async Task Owner_cannot_be_removed_directly()
    {
        var (_, ownerAccountId) = await CreateAccountLinkedDeviceAsync("owner4@example.com");
        var orgId = await CreateOrganizationAsync("Acme");

        var response = await Client.DeleteAsync($"/orgs/{orgId}/members/{ownerAccountId}");
        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("last_owner");
    }

    [Fact]
    public async Task Last_org_admin_cannot_be_demoted_or_removed()
    {
        await CreateAccountLinkedDeviceAsync("owner5@example.com");
        var orgId = await CreateOrganizationAsync("Acme");
        var adminAccountId = Guid.NewGuid();

        (await Client.PutAsJsonAsync($"/orgs/{orgId}/members/{adminAccountId}", new { role = "OrgAdmin" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var demote = await Client.PutAsJsonAsync($"/orgs/{orgId}/members/{adminAccountId}", new { role = "Member" });
        demote.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await demote.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("last_admin");

        var remove = await Client.DeleteAsync($"/orgs/{orgId}/members/{adminAccountId}");
        remove.StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Setting_role_to_owner_is_rejected_as_unsupported_transfer()
    {
        await CreateAccountLinkedDeviceAsync("owner6@example.com");
        var orgId = await CreateOrganizationAsync("Acme");

        var response = await Client.PutAsJsonAsync($"/orgs/{orgId}/members/{Guid.NewGuid()}", new { role = "Owner" });
        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("owner_transfer_unsupported");
    }

    // -----------------------------------------------------------------
    // Invite + enroll
    // -----------------------------------------------------------------

    [Fact]
    public async Task Invite_then_enroll_roundtrip_adds_the_device_and_a_reused_code_is_rejected()
    {
        await CreateAccountLinkedDeviceAsync("owner7@example.com");
        var orgId = await CreateOrganizationAsync("Acme");

        var inviteResponse = await Client.PostAsJsonAsync($"/orgs/{orgId}/invites", new { });
        inviteResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var code = (await inviteResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()!;

        var (memberDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        var enroll = await Client.PostAsJsonAsync("/orgs/enroll", new { code });
        enroll.StatusCode.Should().Be(HttpStatusCode.OK);
        (await enroll.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetGuid().Should().Be(orgId);

        var mine = await Client.GetFromJsonAsync<JsonElement>("/orgs/mine");
        mine.EnumerateArray().Should().ContainSingle(o => o.GetProperty("organizationId").GetGuid() == orgId);

        var reuse = await Client.PostAsJsonAsync("/orgs/enroll", new { code });
        reuse.StatusCode.Should().Be(HttpStatusCode.Gone);
        (await reuse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("invite_invalid");

        _ = memberDeviceId;
    }

    [Fact]
    public async Task Multi_use_invites_are_rejected_as_unsupported()
    {
        await CreateAccountLinkedDeviceAsync("owner8@example.com");
        var orgId = await CreateOrganizationAsync("Acme");

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/invites", new { maxUses = 5 });
        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    // -----------------------------------------------------------------
    // KB6 admin audit — chain continuity + CSV formula-injection escaping
    // -----------------------------------------------------------------

    [Fact]
    public async Task Admin_audit_records_every_mutation_in_a_continuous_chain()
    {
        await CreateAccountLinkedDeviceAsync("owner9@example.com");
        var orgId = await CreateOrganizationAsync("Acme");
        await Client.PutAsJsonAsync($"/orgs/{orgId}/members/{Guid.NewGuid()}", new { role = "Member" });

        var audit = await Client.GetFromJsonAsync<JsonElement>($"/orgs/{orgId}/admin-audit");
        var events = audit.EnumerateArray().ToList();

        events.Should().HaveCount(2); // org_created, member_added
        events.Select(e => e.GetProperty("sequence").GetInt64()).Should().Equal(1, 2);
    }

    [Fact]
    public async Task Admin_audit_csv_export_never_starts_a_cell_with_a_formula_from_the_org_name()
    {
        await CreateAccountLinkedDeviceAsync("owner10@example.com");
        // The org name flows into AdminAuditEvent.DetailsJson for "org_created" —
        // a name starting with '=' is the formula-injection input for KB6. The name
        // lands INSIDE the JSON details cell (which starts with '{'), so a spreadsheet
        // never evaluates it; the quote-prefixing of cells that do start with '=' is
        // covered by OrganizationCsvEscapingTests.
        var response = await Client.PostAsJsonAsync("/orgs", new { name = "=cmd|' /C calc'!A1" });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var orgId = Guid.Parse((await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetString()!);

        var csv = await Client.GetStringAsync($"/orgs/{orgId}/admin-audit?format=csv");
        csv.Should().Contain("=cmd", "the event with the hostile name must be in the export");
        csv.Should().NotContain(",\"=", "no cell may start with '='");
        csv.Should().NotContain("\n\"=", "no cell may start with '='");
    }

    // -----------------------------------------------------------------
    // Business mode disabled
    // -----------------------------------------------------------------

    [Fact]
    public async Task Endpoints_return_503_when_business_mode_is_disabled()
    {
        // A fresh, minimal factory with no ConnectionStrings:Audit configured —
        // BusinessModeOptions.Enabled is false and AuditDbContext is never registered.
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Audit"] = "" })));

        // Authenticated on purpose: auth runs before the handler, so an anonymous
        // call gets 401 and never reveals whether business mode is on. The token is
        // valid here because the derived factory shares the JWT secret and database.
        var (_, token, _) = await RegisterAndAuthenticateAsync();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        var response = await client.PostAsJsonAsync("/orgs", new { name = "Acme" });
        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("business_mode_disabled");
    }
}
