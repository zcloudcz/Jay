// ---------------------------------------------------------------------------
// AuditRoleMutationTests.cs — W2-D: the production audit role must be able
// to run the whole Business mode lifecycle, not just append AuditRecords
// ---------------------------------------------------------------------------
// BusinessModeIntegrationTests proves calltype_audit_app CANNOT UPDATE/DELETE
// an AuditRecord (KB3, append-only). This class proves the complementary
// half that beta was missing: the same role CAN perform every write the
// running API actually issues — including the ones that UPDATE an existing
// row (Organizations, OrgMembers, OrgInvites, OrgEnrollments, EmergencyKits,
// EmergencyEnrollmentCodes, EmergencyDrills — see infra/postgres/audit-roles.sql
// for the column-by-column rationale). Before the W2-D fix, every one of
// those calls failed with PostgreSQL 42501 (insufficient_privilege), which
// the API surfaces as an unhandled 500 — nobody noticed because
// IntegrationTestBase's own DbContext connects as the Testcontainers
// superuser, not as calltype_audit_app.
//
// Drives the whole thing over real HTTP against a factory whose
// ConnectionStrings:Audit is deliberately pointed at the restricted role —
// exactly the beta configuration — then asserts, over a raw Npgsql
// connection as calltype_audit_app, that UPDATE/DELETE are STILL denied on
// every append-only table (the fix must not have loosened KB3).
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Npgsql;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Audit;

public class AuditRoleMutationTests : IntegrationTestBase
{
    private const string AppPassword = "test-only-mutation-app-password";

    private static readonly string IdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string SignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);
    private static readonly string AuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    [Fact]
    public async Task App_role_can_run_the_full_business_lifecycle_and_append_only_tables_stay_locked_down()
    {
        // The script must be re-runnable — the documented ops procedure is
        // "run script -> migrate -> run script again" (see audit-roles.sql
        // header). Applying it twice here proves that, and also proves the
        // per-table UPDATE grants actually land (the test schema already
        // exists via EnsureCreatedAsync in IntegrationTestBase, so both runs
        // reach real tables, not just the ALTER DEFAULT PRIVILEGES path).
        await ApplyAuditRolesScriptAsync(AuditConnectionString, AppPassword);
        await ApplyAuditRolesScriptAsync(AuditConnectionString, AppPassword);

        var appConnectionString = new NpgsqlConnectionStringBuilder(AuditConnectionString)
        {
            Username = "calltype_audit_app",
            Password = AppPassword
        }.ConnectionString;

        // A derived factory whose Audit connection string uses the restricted
        // role — this is what beta actually runs (App Service's
        // ConnectionStrings__Audit), unlike the base fixture's superuser
        // AuditDbContext. Needs its OWN HttpClient: RegisterAndAuthenticateAsync
        // on the base class re-points the shared Client's Bearer token to
        // whichever device it last registered, which would collide with the
        // multiple identities (admin, bot auditor, member device) this test
        // needs live at once.
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["ConnectionStrings:Audit"] = appConnectionString
                })));
        using var client = factory.CreateClient();

        // --- account + device link (governance is per-account) -------------
        var (adminDeviceId, adminToken) = await RegisterDeviceAsync(client, isBot: false);
        Authorize(client, adminToken);
        var accountId = await RegisterAccountAsync(client, "w2d-admin@example.com");
        await LinkDeviceAsync(client, accountId, adminDeviceId);

        // --- POST /orgs (INSERT Organizations, INSERT AdminAuditEvents) ----
        var orgId = await PostJsonExpectOk<Guid>(client, HttpMethod.Post, "/orgs", new { name = "W2-D Org" },
            HttpStatusCode.Created, "organizationId");

        // --- register the auditor bot device and PUT /orgs/{id}/auditor
        //     (UPDATE Organizations.AuditorDeviceId) --------------------------
        var (botDeviceId, botToken) = await RegisterDeviceAsync(client, isBot: true);
        Authorize(client, adminToken);
        await SendExpect(client, HttpMethod.Put, $"/orgs/{orgId}/auditor", new { deviceId = botDeviceId }, HttpStatusCode.NoContent);

        // --- PATCH /orgs/{id} (UPDATE Organizations.Name/ArchiveLevel) ------
        await SendExpect(client, HttpMethod.Patch, $"/orgs/{orgId}", new { name = "W2-D Org Renamed", archiveLevel = "Metadata" }, HttpStatusCode.NoContent);

        // --- PUT /orgs/{id}/members/{accountId} twice: first call INSERTs
        //     (AddMember), second call UPDATEs (ChangeMemberRole). Both as
        //     plain Member — Organization.ChangeMemberRole refuses to demote
        //     the org's only active OrgAdmin (last_admin invariant), so an
        //     OrgAdmin round trip here would need a SECOND admin first; a
        //     Member->Member "change" (still exercises the UPDATE branch,
        //     SetMemberRoleAsync always writes even for a no-op role) avoids
        //     that unrelated invariant entirely. --------------------------
        var otherAccountId = Guid.NewGuid();
        await SendExpect(client, HttpMethod.Put, $"/orgs/{orgId}/members/{otherAccountId}", new { role = "Member" }, HttpStatusCode.NoContent);
        await SendExpect(client, HttpMethod.Put, $"/orgs/{orgId}/members/{otherAccountId}", new { role = "Member" }, HttpStatusCode.NoContent);
        // DELETE /orgs/{id}/members/{accountId} (UPDATE OrgMembers.RemovedAt, soft)
        await SendExpect(client, HttpMethod.Delete, $"/orgs/{orgId}/members/{otherAccountId}", null, HttpStatusCode.NoContent);

        // --- POST /orgs/{id}/invites (INSERT OrgInvites) --------------------
        var inviteCode = await PostJsonExpectOk<string>(client, HttpMethod.Post, $"/orgs/{orgId}/invites", new { }, HttpStatusCode.OK, "code");

        // --- POST /orgs/enroll (UPDATE OrgInvites.UsedAt, INSERT OrgEnrollments) ---
        var (memberDeviceId, memberToken) = await RegisterDeviceAsync(client, isBot: false);
        Authorize(client, memberToken);
        await SendExpect(client, HttpMethod.Post, "/orgs/enroll", new { code = inviteCode }, HttpStatusCode.OK);

        // --- DELETE /orgs/{id}/enrollments/{deviceId} (UPDATE OrgEnrollments.RevokedAt) ---
        Authorize(client, adminToken);
        await SendExpect(client, HttpMethod.Delete, $"/orgs/{orgId}/enrollments/{memberDeviceId}", null, HttpStatusCode.NoContent);

        // --- POST /orgs/{id}/emergency/kits (INSERT EmergencyKits + codes) --
        var kitId = await PostJsonExpectOk<Guid>(client, HttpMethod.Post, $"/orgs/{orgId}/emergency/kits",
            new { label = "Kit 1", count = 1 }, HttpStatusCode.OK, "kitId");
        var kitBody = await GetJsonAsync(client, HttpMethod.Post, $"/orgs/{orgId}/emergency/kits", new { label = "Kit 2", count = 1 });
        // EnrollAsync only matches against EmergencyEnrollmentCodes (the
        // per-device "codes" array) — the kit-level "recoveryCode" hashes
        // into EmergencyKit.RecoveryCodeHash instead and is never looked up
        // by EnrollAsync, so it can't be used to enroll a device.
        var deviceCode = kitBody.GetProperty("codes")[0].GetString()!;

        // --- POST /orgs/emergency/enroll (UPDATE EmergencyEnrollmentCodes.UsedAt) ---
        // The enrolling device is whichever device the Bearer token identifies
        // (EmergencyEndpoints.Enroll reads it from the JWT, not the body) — any
        // authenticated device works, spec 2.3's whole point being that it
        // need not be linked to an account.
        var (emergencyDeviceId, emergencyToken) = await RegisterDeviceAsync(client, isBot: false);
        Authorize(client, emergencyToken);
        await SendExpect(client, HttpMethod.Post, "/orgs/emergency/enroll", new { code = deviceCode }, HttpStatusCode.OK);

        // --- POST .../emergency/drills (INSERT EmergencyDrills), confirm
        //     (INSERT EmergencyDrillConfirmations, UPDATE EmergencyDrills.ConfirmedMemberCount),
        //     complete (UPDATE EmergencyDrills.CompletedAt/ResponseTime) -----
        // StartDrill/CompleteDrill require an account (RequireAccountAsync) —
        // switch back to the admin; the client is still on emergencyToken
        // (a bare device, no linked account) from the enroll call above.
        Authorize(client, adminToken);
        var drillBody = await GetJsonAsync(client, HttpMethod.Post, $"/orgs/{orgId}/emergency/drills", null);
        var drillId = drillBody.GetProperty("drillId").GetInt64();
        await SendExpect(client, HttpMethod.Post, $"/orgs/{orgId}/emergency/drills/{drillId}/confirm", null, HttpStatusCode.NoContent);
        await SendExpect(client, HttpMethod.Post, $"/orgs/{orgId}/emergency/drills/{drillId}/complete", null, HttpStatusCode.NoContent);

        // --- DELETE .../emergency/kits/{kitId} (UPDATE EmergencyKits.RevokedAt) ---
        Authorize(client, adminToken);
        await SendExpect(client, HttpMethod.Delete, $"/orgs/{orgId}/emergency/kits/{kitId}", null, HttpStatusCode.NoContent);

        // --- POST /groups/business (Delivery DB — proves the Audit-DB
        //     precondition reads (Organizations.AuditorDeviceId,
        //     OrgEnrollments) still work under the restricted role). The
        //     creator must be actively enrolled — emergencyDeviceId is, via
        //     the OrgEnrollment the emergency enroll call just created.
        Authorize(client, emergencyToken);
        await SendExpect(client, HttpMethod.Post, "/groups/business", new { organizationId = orgId, memberDeviceIds = Array.Empty<Guid>() },
            HttpStatusCode.Created);

        // --- archiver write: POST /orgs/{id}/audit/records, authenticated
        //     as the auditor bot device (INSERT AuditRecords) --------------
        Authorize(client, botToken);
        await SendExpect(client, HttpMethod.Post, $"/orgs/{orgId}/audit/records", new
        {
            groupId = Guid.NewGuid(),
            messageId = Guid.NewGuid(),
            senderDeviceId = memberDeviceId,
            sentAt = DateTimeOffset.UtcNow,
            kind = "text",
            sizeBytes = 10,
            contentHash = Convert.ToHexString(new byte[32])
        }, HttpStatusCode.OK);

        // --- GET /orgs/{id}/admin-audit (SELECT AdminAuditEvents) ----------
        Authorize(client, adminToken);
        var adminAuditResponse = await client.GetAsync($"/orgs/{orgId}/admin-audit");
        adminAuditResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        // --- KB3 must still hold: UPDATE/DELETE denied on every append-only
        //     table, and DELETE denied on every table (no DELETE code path
        //     exists anywhere in the application against the Audit database).
        await using var appConn = new NpgsqlConnection(appConnectionString);
        await appConn.OpenAsync();

        // (table, a column that actually exists on it — most have "Id", but
        // DailyRoots is keyed by "Day" and AuditAccessRequests by "RequestId").
        (string Table, string Column)[] appendOnlyTables =
        [
            ("AuditRecords", "Id"), ("AdminAuditEvents", "Id"), ("AuditAccessLogs", "Id"),
            ("DailyRoots", "Day"), ("OrgDailyProofs", "Id"),
            ("EmergencyDrillConfirmations", "Id"), ("AuditAccessRequests", "RequestId")
        ];
        foreach (var (table, column) in appendOnlyTables)
        {
            await AssertDeniedAsync(appConn, $"UPDATE \"{table}\" SET \"{column}\" = \"{column}\";");
            await AssertDeniedAsync(appConn, $"DELETE FROM \"{table}\";");
        }

        string[] mutableTables =
        [
            "Organizations", "OrgMembers", "OrgInvites", "OrgEnrollments",
            "EmergencyKits", "EmergencyEnrollmentCodes", "EmergencyDrills"
        ];
        foreach (var table in mutableTables)
            await AssertDeniedAsync(appConn, $"DELETE FROM \"{table}\";");
    }

    private static async Task AssertDeniedAsync(NpgsqlConnection conn, string sql)
    {
        var attempt = async () =>
        {
            await using var cmd = new NpgsqlCommand(sql, conn);
            await cmd.ExecuteNonQueryAsync();
        };
        await attempt.Should().ThrowAsync<PostgresException>()
            .Where(e => e.SqlState == PostgresErrorCodes.InsufficientPrivilege);
    }

    // -----------------------------------------------------------------
    // HTTP plumbing — deliberately independent of IntegrationTestBase's
    // Client/RegisterAndAuthenticateAsync (see the pitfall noted at the top).
    // -----------------------------------------------------------------

    private static void Authorize(HttpClient client, string token) =>
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

    private static async Task<(Guid DeviceId, string Token)> RegisterDeviceAsync(HttpClient client, bool isBot)
    {
        var response = await client.PostAsJsonAsync("/devices", new { identityKey = IdentityKey, signedPreKey = SignedPreKey, isBot });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = Guid.Parse(body.GetProperty("deviceId").GetString()!);
        var deviceSecret = body.GetProperty("deviceSecret").GetString()!;

        var (_, token) = await ExchangeForTokenAsync(client, deviceId, deviceSecret);
        return (deviceId, token);
    }

    private static async Task<(Guid DeviceId, string Token)> ExchangeForTokenAsync(HttpClient client, Guid deviceId, string deviceSecret)
    {
        var response = await client.PostAsJsonAsync("/auth/token", new { deviceId, deviceSecret });
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return (deviceId, body.GetProperty("token").GetString()!);
    }

    private static async Task<Guid> RegisterAccountAsync(HttpClient client, string email)
    {
        var response = await client.PostAsJsonAsync("/accounts", new { email, authKey = AuthKey });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return Guid.Parse(body.GetProperty("accountId").GetString()!);
    }

    private static async Task LinkDeviceAsync(HttpClient client, Guid accountId, Guid deviceId)
    {
        var response = await client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = AuthKey });
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    private static async Task SendExpect(HttpClient client, HttpMethod method, string url, object? body, HttpStatusCode expected)
    {
        using var request = new HttpRequestMessage(method, url);
        if (body is not null) request.Content = JsonContent.Create(body);
        var response = await client.SendAsync(request);
        response.StatusCode.Should().Be(expected, await response.Content.ReadAsStringAsync());
    }

    private static async Task<JsonElement> GetJsonAsync(HttpClient client, HttpMethod method, string url, object? body)
    {
        using var request = new HttpRequestMessage(method, url);
        if (body is not null) request.Content = JsonContent.Create(body);
        var response = await client.SendAsync(request);
        response.StatusCode.Should().BeOneOf(HttpStatusCode.OK, HttpStatusCode.Created);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }

    private static async Task<T> PostJsonExpectOk<T>(HttpClient client, HttpMethod method, string url, object body,
        HttpStatusCode expected, string property)
    {
        var json = await GetJsonAsyncExpect(client, method, url, body, expected);
        var element = json.GetProperty(property);
        return typeof(T) == typeof(Guid) ? (T)(object)element.GetGuid() : (T)(object)element.GetString()!;
    }

    private static async Task<JsonElement> GetJsonAsyncExpect(HttpClient client, HttpMethod method, string url, object body, HttpStatusCode expected)
    {
        using var request = new HttpRequestMessage(method, url) { Content = JsonContent.Create(body) };
        var response = await client.SendAsync(request);
        response.StatusCode.Should().Be(expected, await response.Content.ReadAsStringAsync());
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
}
