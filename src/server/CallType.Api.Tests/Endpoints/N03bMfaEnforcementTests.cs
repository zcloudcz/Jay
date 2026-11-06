// ---------------------------------------------------------------------------
// N03bMfaEnforcementTests.cs — MFA step-up enforcement on OrgAdmin+ routes (N03b)
// ---------------------------------------------------------------------------
// MfaAuthHelperTests already covers RequireStepUp's own claims logic (expiry,
// wrong account) as a pure unit test. This file proves the WIRING: that the
// listed OrgAdmin+ routes in OrganizationEndpoints/EmergencyEndpoints/
// AuditArchiveEndpoints actually call it, in the right order relative to the
// pre-existing membership/role check (AssertAdmin) — a non-member gets
// exactly today's 403 "forbidden", never "mfa_required".
//
// Table-driven over the route list from docs/superpowers/plans/
// 2026-09-18-business-mode-contracts.md "N03 — MFA" so adding/removing a
// gated route is a one-line change here, not a new test method.
// ---------------------------------------------------------------------------

using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace CallType.Api.Tests.Endpoints;

public class N03bMfaEnforcementTests : IntegrationTestBase
{
    private static readonly string ValidAuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    /// <summary>One request per gated route — enough to prove RequireStepUp
    /// was actually called, not to exercise each route's business logic
    /// (that's OrganizationEndpointsTests/EmergencyEndpointsTests's job).</summary>
    private static readonly (HttpMethod Method, string Path, object? Body)[] GatedRoutes =
    [
        (HttpMethod.Patch, "/orgs/{id}", null),
        // Needs a body that passes input validation (Enum.TryParse<OrgRole>)
        // BEFORE the request ever reaches the step-up gate — that ordering
        // (validate shape, then check auth) predates N03b and is unrelated
        // to it, so the test supplies a valid role rather than an empty body.
        (HttpMethod.Put, "/orgs/{id}/members/00000000-0000-0000-0000-000000000001", new { role = "Member" }),
        (HttpMethod.Delete, "/orgs/{id}/members/00000000-0000-0000-0000-000000000001", null),
        (HttpMethod.Post, "/orgs/{id}/invites", null),
        (HttpMethod.Delete, "/orgs/{id}/enrollments/00000000-0000-0000-0000-000000000001", null),
        (HttpMethod.Put, "/orgs/{id}/auditor", null),
        (HttpMethod.Get, "/orgs/{id}/admin-audit", null),
        (HttpMethod.Post, "/orgs/{id}/emergency/kits", null),
        (HttpMethod.Get, "/orgs/{id}/emergency/kits", null),
        (HttpMethod.Delete, "/orgs/{id}/emergency/kits/00000000-0000-0000-0000-000000000001", null),
        (HttpMethod.Post, "/orgs/{id}/emergency/drills", null),
        (HttpMethod.Post, "/orgs/{id}/emergency/drills/1/complete", null),
        (HttpMethod.Get, "/orgs/{id}/emergency/drills", null),
        (HttpMethod.Get, "/orgs/{id}/emergency/proof", null),
    ];

    private async Task<(Guid DeviceId, Guid AccountId, string PlainToken)> CreateOrgOwnerAsync(string email)
    {
        var (deviceId, token, _) = await RegisterAndAuthenticateAsync();
        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        var accountId = Guid.Parse((await accountResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetString()!);
        (await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey }))
            .StatusCode.Should().Be(HttpStatusCode.OK);
        return (deviceId, accountId, token);
    }

    private async Task<Guid> CreateOrganizationAsync()
    {
        var response = await Client.PostAsJsonAsync("/orgs", new { name = "N03b Acme" });
        return Guid.Parse((await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetString()!);
    }

    private static void UseToken(HttpClient client, string token) =>
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

    private static Task<HttpResponseMessage> SendAsync(HttpClient client, HttpMethod method, string path, Guid orgId, object? body)
    {
        var url = path.Replace("{id}", orgId.ToString());
        var request = new HttpRequestMessage(method, url);
        if (method == HttpMethod.Patch || method == HttpMethod.Post || method == HttpMethod.Put)
            request.Content = JsonContent.Create(body ?? new { });
        return client.SendAsync(request);
    }

    [Theory]
    [MemberData(nameof(GatedRouteCases))]
    public async Task Every_listed_route_requires_a_fresh_step_up_and_succeeds_or_fails_business_logic_once_stepped_up(
        HttpMethod method, string path, object? body)
    {
        var (deviceId, accountId, plainToken) = await CreateOrgOwnerAsync($"n03b-{Guid.NewGuid():N}@example.com");
        var orgId = await CreateOrganizationAsync();

        // Without a step-up: 403 mfa_required, even though the caller IS the
        // org's Owner (proves membership/role was already established before
        // this check ran — see RequireOrgAdminThenStepUpAsync).
        UseToken(Client, plainToken);
        var withoutStepUp = await SendAsync(Client, method, path, orgId, body);
        withoutStepUp.StatusCode.Should().Be(HttpStatusCode.Forbidden, $"{method} {path} without MFA");
        (await withoutStepUp.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_required");

        // With a step-up: the request reaches business logic — asserting
        // "not mfa_required" is deliberately weaker than a specific status,
        // since some routes 404/422/OK depending on the throwaway ids above;
        // what matters here is that RequireStepUp let it through.
        var stepUpToken = await EnrollAndVerifyMfaAsync(Client, accountId, ValidAuthKey);
        UseToken(Client, stepUpToken);
        var withStepUp = await SendAsync(Client, method, path, orgId, body);
        if (withStepUp.StatusCode == HttpStatusCode.Forbidden)
        {
            var responseBody = await withStepUp.Content.ReadFromJsonAsync<JsonElement>();
            responseBody.TryGetProperty("code", out var code).Should().BeTrue();
            code.GetString().Should().NotBe("mfa_required", $"{method} {path} with a fresh step-up token");
        }

        _ = deviceId;
    }

    public static IEnumerable<object[]> GatedRouteCases() => GatedRoutes.Select(r => new object[] { r.Method, r.Path, r.Body! });

    [Fact]
    public async Task NonMember_gets_forbidden_never_mfa_required()
    {
        await CreateOrgOwnerAsync($"n03b-owner-{Guid.NewGuid():N}@example.com");
        var orgId = await CreateOrganizationAsync();

        // A second, unrelated account+device — never a member of orgId, and
        // never enrolled in MFA either. The membership/role check
        // (OrganizationAppService.AssertAdmin, pre-existing, unchanged by
        // N03b) must fire BEFORE the MFA gate, so this stays 403 "forbidden"
        // exactly as it was before N03b — never 403 "mfa_required".
        var (_, _, strangerToken) = await CreateOrgOwnerAsync($"n03b-stranger-{Guid.NewGuid():N}@example.com");
        UseToken(Client, strangerToken);

        var response = await Client.PatchAsync($"/orgs/{orgId}", JsonContent.Create(new { name = "Hostile Rename" }));

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("forbidden");
    }

    [Fact]
    public async Task Expired_step_up_is_refused()
    {
        var (_, accountId, plainToken) = await CreateOrgOwnerAsync($"n03b-expiry-{Guid.NewGuid():N}@example.com");
        var orgId = await CreateOrganizationAsync();

        var clock = new FakeTimeProvider(DateTimeOffset.UtcNow);
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureServices(services => services.AddSingleton<TimeProvider>(clock)));
        using var client = factory.CreateClient();
        // The derived factory inherits the base factory's Jwt:Secret/database
        // (same pitfall MfaEndpointsTests documents), so the plain token minted
        // through the base Client is valid here too — needed to authenticate
        // the enroll/confirm/verify calls below.
        UseToken(client, plainToken);

        // The server reads the frozen fake clock, so the codes must come from it.
        var stepUpToken = await EnrollAndVerifyMfaAsync(client, accountId, ValidAuthKey, clock);
        UseToken(client, stepUpToken);

        clock.Advance(TimeSpan.FromMinutes(20)); // past Mfa:StepUpMinutes (default 15)

        var response = await client.PatchAsync($"/orgs/{orgId}", JsonContent.Create(new { name = "Too Late" }));

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_required");
    }

    [Fact]
    public async Task StepUp_for_a_different_account_is_refused_even_for_that_accounts_own_org()
    {
        var (_, accountA, _) = await CreateOrgOwnerAsync($"n03b-a-{Guid.NewGuid():N}@example.com");
        var orgIdOfA = await CreateOrganizationAsync();
        var stepUpTokenForA = await EnrollAndVerifyMfaAsync(Client, accountA, ValidAuthKey);

        // Account B owns its OWN org — the step-up token above proves MFA for
        // A, not B, so it must not unlock B's admin actions even though B
        // really is that org's Owner.
        var (_, accountB, _) = await CreateOrgOwnerAsync($"n03b-b-{Guid.NewGuid():N}@example.com");
        var orgIdOfB = await CreateOrganizationAsync();
        _ = accountB;

        UseToken(Client, stepUpTokenForA);
        var response = await Client.PatchAsync($"/orgs/{orgIdOfB}", JsonContent.Create(new { name = "Borrowed Token" }));

        // The device behind stepUpTokenForA is A's device, which the server
        // resolves back to accountA via the linked-device lookup — RequireStepUp
        // compares against accountA, and accountA is not a member of orgIdOfB,
        // so this fails at the membership check (403 "forbidden", same as the
        // pre-existing AssertAdmin rule) — either way, never granted.
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("forbidden");
        _ = orgIdOfA;
    }

    [Fact]
    public async Task Without_MfaEncryptionKey_PrivilegedEndpoints_StayLocked()
    {
        // No token can ever carry a valid amr=totp claim if nothing can enrol
        // (MfaEndpoints answers 503 mfa_not_configured) — RequireStepUp must
        // still see "no step-up" and refuse with 403, never silently open up.
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?> { ["Mfa:EncryptionKey"] = "" })));
        using var client = factory.CreateClient();

        var (deviceId, token, _) = await RegisterAndAuthenticateAsync();
        UseToken(client, token);
        var email = $"n03b-nokey-{Guid.NewGuid():N}@example.com";
        var accountResponse = await client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        var accountId = Guid.Parse((await accountResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetString()!);
        (await client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey }))
            .StatusCode.Should().Be(HttpStatusCode.OK);
        var orgResponse = await client.PostAsJsonAsync("/orgs", new { name = "No Key Org" });
        var orgId = Guid.Parse((await orgResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("organizationId").GetString()!);

        // Enrolling is impossible on this factory (503 mfa_not_configured) —
        // confirmed here so the assertion below can't be blamed on a typo'd URL.
        var enrollAttempt = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/start", new { authKey = ValidAuthKey });
        enrollAttempt.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);

        var response = await client.PatchAsync($"/orgs/{orgId}", JsonContent.Create(new { name = "Still Locked" }));

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_required");
    }
}
