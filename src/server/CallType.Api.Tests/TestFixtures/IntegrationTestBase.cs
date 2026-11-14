// ---------------------------------------------------------------------------
// IntegrationTestBase.cs — Shared test infrastructure for integration tests
// ---------------------------------------------------------------------------
// Runs every test against a real PostgreSQL and an Azurite (Azure Blob
// Storage emulator) via Testcontainers, no in-memory fakes that silently
// diverge from production.
//
// Implements IAsyncLifetime, which xUnit 2 runs per TEST:
//   InitializeAsync  -> fresh databases for this test, WebApplicationFactory
//   DisposeAsync     -> dispose the factory, drop this test's databases
// The containers themselves are shared by the whole run (SharedContainers),
// except for tests that set UseDedicatedPostgres.
//
// Test classes inherit this and get Factory + Client ready to use.
// Provides RegisterAndAuthenticateAsync() so tests that hit protected
// endpoints can obtain a valid JWT without boilerplate.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Testcontainers.PostgreSql;
using CallType.Api.Data;
using CallType.Api.Services;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.TestFixtures;

public abstract class IntegrationTestBase : IAsyncLifetime
{
    /// <summary>
    /// Set to true in a test class that changes cluster-wide Postgres state,
    /// such as the roles in infra/postgres/audit-roles.sql. Roles are global
    /// to a Postgres cluster, and the script targets the database name
    /// calltype_audit, so such tests get their own container with the audit
    /// database under exactly that name, as every test had before the
    /// containers were shared.
    /// </summary>
    protected virtual bool UseDedicatedPostgres => false;

    private PostgreSqlContainer? _dedicatedPostgres;
    private string _postgresConnectionString = null!;
    private string _azuriteConnectionString = null!;

    /// <summary>
    /// The fully configured test server. Use it to resolve services
    /// (e.g. DbContext) or create additional HttpClients.
    /// </summary>
    protected WebApplicationFactory<Program> Factory { get; private set; } = null!;

    /// <summary>
    /// Pre-built HttpClient pointing at the test server.
    /// </summary>
    protected HttpClient Client { get; private set; } = null!;

    /// <summary>
    /// Connection string for the Audit (business mode) database, a second,
    /// physically separate database on the same Postgres instance, mirroring
    /// production's separate-DB-separate-credentials rule (KB3).
    /// Exposed so tests can open their own connection (e.g. to apply
    /// infra/postgres/audit-roles.sql and verify the restricted app role).
    /// </summary>
    protected string AuditConnectionString { get; private set; } = null!;

    // Reusable key material for the auth helper. Tests that need specific keys
    // can still register devices manually.
    private static readonly string DefaultIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string DefaultSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    public async Task InitializeAsync()
    {
        _azuriteConnectionString = await SharedContainers.AzuriteConnectionStringAsync();

        if (UseDedicatedPostgres)
        {
            _dedicatedPostgres = SharedContainers.BuildPostgres();
            await _dedicatedPostgres.StartAsync();
            _postgresConnectionString = SharedContainers.ConnectionString(_dedicatedPostgres);
            // Business mode's Audit database lives alongside the Delivery one
            // in the same Postgres instance, under its own database name.
            await SharedContainers.ExecuteWithRetryAsync(_postgresConnectionString,
                "CREATE DATABASE calltype_audit;", PostgresErrorCodes.DuplicateDatabase);
            AuditConnectionString = SharedContainers.ConnectionString(_dedicatedPostgres, "calltype_audit");
        }
        else
        {
            // Copies of the schema templates: same schema as EnsureCreated,
            // empty, and private to this test.
            (_postgresConnectionString, AuditConnectionString) = await SharedContainers.CreateTestDatabasesAsync();
        }

        Factory = new WebApplicationFactory<Program>()
            .WithWebHostBuilder(builder =>
            {
                builder.ConfigureAppConfiguration((_, config) =>
                {
                    config.AddInMemoryCollection(new Dictionary<string, string?>
                    {
                        // TURN shared secret for TurnCredentialService.
                        ["Turn:SharedSecret"] = "test-shared-secret-for-turn",
                        ["Turn:TtlSeconds"] = "3600",
                        // JWT signing key for test token generation. Must be at least
                        // 32 chars for HMAC-SHA256 to accept it.
                        ["Jwt:Secret"] = "test-jwt-secret-at-least-32-characters-long!!",
                        ["Jwt:Issuer"] = "CallType.Api.Tests",
                        // Azurite connection string for blob storage tests.
                        ["ConnectionStrings:BlobStorage"] = _azuriteConnectionString,
                        // Presence of this key is what turns Business mode on
                        // (BusinessModeOptions); Program.cs reads it directly,
                        // so no ConfigureServices override is needed for AuditDbContext.
                        ["ConnectionStrings:Audit"] = AuditConnectionString,
                        // 32 zero bytes, base64; MfaEncryptionService just needs 32 raw
                        // bytes; this is a test fixture, not a production key.
                        ["Mfa:EncryptionKey"] = Convert.ToBase64String(new byte[32]),
                        // P1: OrgCommunicationPolicy's per-device-pair cache would
                        // otherwise make a test that flips RequireBusinessConversations
                        // mid-test see a stale verdict for up to 30 s.
                        ["Business:PolicyCacheSeconds"] = "0"
                    });
                });

                builder.ConfigureServices(services =>
                {
                    // Remove the application's DbContext registration so we
                    // can replace it with one pointing at the test database.
                    var descriptor = services.SingleOrDefault(
                        d => d.ServiceType == typeof(DbContextOptions<AppDbContext>));

                    if (descriptor is not null)
                        services.Remove(descriptor);

                    services.AddDbContext<AppDbContext>(options =>
                        options.UseNpgsql(_postgresConnectionString));

                    // Replace the BlobServiceClient singleton with one pointing
                    // at the Azurite container instead of real Azure.
                    var blobDescriptor = services.SingleOrDefault(
                        d => d.ServiceType == typeof(BlobServiceClient));

                    if (blobDescriptor is not null)
                        services.Remove(blobDescriptor);

                    services.AddSingleton(_ =>
                        new BlobServiceClient(_azuriteConnectionString));
                });
            });

        Client = Factory.CreateClient();

        if (UseDedicatedPostgres)
        {
            // Apply the schema to the fresh databases. EnsureCreatedAsync is
            // sufficient here; we don't need migration history tracking in tests.
            using var scope = Factory.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await db.Database.EnsureCreatedAsync();
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            await auditDb.Database.EnsureCreatedAsync();
        }
    }

    /// <summary>
    /// Registers a new device, obtains a JWT, and sets the Bearer header on Client.
    /// Returns the deviceId, token, and userHandle so tests can use them in assertions.
    /// This is the standard way for tests to authenticate before hitting protected endpoints.
    /// </summary>
    protected async Task<(Guid DeviceId, string Token, string UserHandle)> RegisterAndAuthenticateAsync()
    {
        // 1. Register a device (public endpoint — no auth needed).
        var regResponse = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = DefaultIdentityKey,
            signedPreKey = DefaultSignedPreKey
        });

        if (regResponse.StatusCode != HttpStatusCode.Created)
            throw new InvalidOperationException(
                $"Device registration failed with {regResponse.StatusCode}: {await regResponse.Content.ReadAsStringAsync()}");

        var regBody = await regResponse.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = Guid.Parse(regBody.GetProperty("deviceId").GetString()!);
        var userHandle = regBody.GetProperty("userHandle").GetString()!;
        var deviceSecret = regBody.GetProperty("deviceSecret").GetString()!;

        // 2. Exchange the device secret for a JWT (public endpoint).
        var tokenResponse = await Client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret
        });

        if (tokenResponse.StatusCode != HttpStatusCode.OK)
            throw new InvalidOperationException(
                $"Token request failed with {tokenResponse.StatusCode}: {await tokenResponse.Content.ReadAsStringAsync()}");

        var tokenBody = await tokenResponse.Content.ReadFromJsonAsync<JsonElement>();
        var token = tokenBody.GetProperty("token").GetString()!;

        // 3. Set the Authorization header for all subsequent requests on this client.
        Client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);

        return (deviceId, token, userHandle);
    }

    /// <summary>
    /// N03b test helper: enrols TOTP MFA on an already-linked account through
    /// the given (already-authenticated) client, verifies it, and returns the
    /// step-up token — everything OrgAdmin+ endpoints now require. Confirms
    /// with the CURRENT time-step and verifies with the NEXT one so the two
    /// calls consume different steps without a 30s sleep (a step-up code is
    /// single-use per account, see TotpService/MfaEndpoints). The server
    /// accepts steps -1/0/+1, so each code survives one step boundary passing
    /// between computing it and the server checking it. The earlier
    /// previous/current pair did not: on a slow CI runner a boundary crossed
    /// mid-request turned the previous step into -2 (deploy run 42248830094).
    /// <paramref name="clock"/> must be the server's clock when the client's
    /// factory injects a FakeTimeProvider: a frozen server clock
    /// and the real one drift apart while a slow runner builds the factory,
    /// and codes from the real clock were then rejected (deploy run 42285302688).
    /// </summary>
    protected static async Task<string> EnrollAndVerifyMfaAsync(HttpClient client, Guid accountId, string authKey, TimeProvider? clock = null)
    {
        clock ??= TimeProvider.System;
        var startResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/start", new { authKey });
        if (startResponse.StatusCode != HttpStatusCode.OK)
            throw new InvalidOperationException(
                $"MFA enroll/start failed with {startResponse.StatusCode}: {await startResponse.Content.ReadAsStringAsync()}");
        var secretBase32 = (await startResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("secretBase32").GetString()!;
        var secret = Base32.Decode(secretBase32);

        var confirmStep = clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period;
        var confirmResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/confirm",
            new { code = TotpService.ComputeCode(secret, confirmStep) });
        if (confirmResponse.StatusCode != HttpStatusCode.OK)
            throw new InvalidOperationException(
                $"MFA enroll/confirm failed with {confirmResponse.StatusCode}: {await confirmResponse.Content.ReadAsStringAsync()}");

        var verifyStep = Math.Max(confirmStep, clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period) + 1;
        var verifyResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify",
            new { code = TotpService.ComputeCode(secret, verifyStep) });
        if (verifyResponse.StatusCode != HttpStatusCode.OK)
            throw new InvalidOperationException(
                $"MFA verify failed with {verifyResponse.StatusCode}: {await verifyResponse.Content.ReadAsStringAsync()}");

        return (await verifyResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
    }

    /// <summary>
    /// Applies infra/postgres/audit-roles.sql verbatim (with the placeholder
    /// passwords substituted) against the given Audit database connection
    /// string, exactly as an ops runbook would against production. Shared by
    /// BusinessModeIntegrationTests (proves the app role can't UPDATE/DELETE
    /// an AuditRecord) and AuditRoleMutationTests (proves the app role CAN do
    /// every mutation the application needs) so the two test classes don't
    /// duplicate the plumbing for reading and running the checked-in script.
    /// </summary>
    protected static async Task ApplyAuditRolesScriptAsync(string auditConnectionString, string appPassword)
    {
        var scriptPath = Path.Combine(FindRepoRoot(), "infra", "postgres", "audit-roles.sql");
        var script = await File.ReadAllTextAsync(scriptPath);
        script = script.Replace("REPLACE_ME_OPS", "test-only-ops-password")
                        .Replace("REPLACE_ME", appPassword);

        await using var conn = new NpgsqlConnection(auditConnectionString);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(script, conn);
        await cmd.ExecuteNonQueryAsync();
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "CallType.sln")))
            dir = dir.Parent;

        return dir?.FullName
            ?? throw new InvalidOperationException("Could not locate repo root (CallType.sln) from the test output directory.");
    }

    public async Task DisposeAsync()
    {
        Client?.Dispose();
        if (Factory is not null)
            await Factory.DisposeAsync();

        if (_dedicatedPostgres is not null)
            await _dedicatedPostgres.DisposeAsync();
        else if (_postgresConnectionString is not null)
            await SharedContainers.DropTestDatabasesAsync(_postgresConnectionString, AuditConnectionString);
    }
}
