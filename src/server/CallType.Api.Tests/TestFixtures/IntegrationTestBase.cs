// ---------------------------------------------------------------------------
// IntegrationTestBase.cs — Shared test infrastructure for integration tests
// ---------------------------------------------------------------------------
// Spins up a real PostgreSQL container and an Azurite container (Azure Blob
// Storage emulator) via Testcontainers so every test class runs against
// genuine services — no in-memory fakes that silently diverge from production.
//
// Implements IAsyncLifetime so xUnit manages the container lifecycle:
//   InitializeAsync  -> start containers, build WebApplicationFactory, apply schema
//   DisposeAsync     -> tear down containers and factory
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
using Testcontainers.Azurite;
using Testcontainers.PostgreSql;
using CallType.Api.Data;
using CallType.Api.Services;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.TestFixtures;

public abstract class IntegrationTestBase : IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder("postgres:17-alpine")
        .Build();

    // Azurite emulates Azure Blob Storage locally. Backup upload/download tests
    // exercise real blob I/O instead of mocking the BlobServiceClient.
    // skipApiVersionCheck is required because Azure.Storage.Blobs SDK v12.28+
    // uses API version 2026-04-06 which the latest Azurite image doesn't yet
    // recognize. The flag tells Azurite to accept any API version.
    private readonly AzuriteContainer _azurite = new AzuriteBuilder("mcr.microsoft.com/azure-storage/azurite:latest")
        .WithCommand("--skipApiVersionCheck")
        .Build();

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
    /// Connection string for the Audit (business mode) database — a second,
    /// physically separate database on the same Testcontainers Postgres
    /// instance, mirroring production's separate-DB-separate-credentials
    /// rule (KB3) without paying for a second container per test class.
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
        // Start both containers in parallel — they are independent services.
        await Task.WhenAll(
            _postgres.StartAsync(),
            _azurite.StartAsync());

        // Business mode's Audit database lives alongside the Delivery one in
        // the same Postgres instance, under its own database name — see
        // CreateAuditDatabaseAsync for why a second CREATE DATABASE is enough
        // here instead of a second Testcontainer.
        AuditConnectionString = await CreateAuditDatabaseAsync();

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
                        ["ConnectionStrings:BlobStorage"] = _azurite.GetConnectionString(),
                        // Presence of this key is what turns Business mode on
                        // (BusinessModeOptions) — Program.cs reads it directly,
                        // so no ConfigureServices override is needed for AuditDbContext.
                        ["ConnectionStrings:Audit"] = AuditConnectionString,
                        // 32 zero bytes, base64 — MfaEncryptionService just needs 32 raw
                        // bytes; this is a test fixture, not a production key.
                        ["Mfa:EncryptionKey"] = Convert.ToBase64String(new byte[32])
                    });
                });

                builder.ConfigureServices(services =>
                {
                    // Remove the application's DbContext registration so we
                    // can replace it with one pointing at the container.
                    var descriptor = services.SingleOrDefault(
                        d => d.ServiceType == typeof(DbContextOptions<AppDbContext>));

                    if (descriptor is not null)
                        services.Remove(descriptor);

                    services.AddDbContext<AppDbContext>(options =>
                        options.UseNpgsql(_postgres.GetConnectionString()));

                    // Replace the BlobServiceClient singleton with one pointing
                    // at the Azurite container instead of real Azure.
                    var blobDescriptor = services.SingleOrDefault(
                        d => d.ServiceType == typeof(BlobServiceClient));

                    if (blobDescriptor is not null)
                        services.Remove(blobDescriptor);

                    services.AddSingleton(_ =>
                        new BlobServiceClient(_azurite.GetConnectionString()));
                });
            });

        Client = Factory.CreateClient();

        // Apply the schema to the fresh databases. EnsureCreatedAsync is
        // sufficient here — we don't need migration history tracking in tests.
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.EnsureCreatedAsync();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        await auditDb.Database.EnsureCreatedAsync();
    }

    /// <summary>
    /// Creates a second database ("calltype_audit") on the same Testcontainers
    /// Postgres instance and returns a connection string for it. A second
    /// CREATE DATABASE is enough to prove separation-of-databases at the
    /// application level (KB3) without the cost of a second Postgres
    /// container per test class; the separation-of-CREDENTIALS half of KB3 is
    /// what BusinessModeIntegrationTests verifies by applying
    /// infra/postgres/audit-roles.sql against this same database.
    /// </summary>
    private async Task<string> CreateAuditDatabaseAsync()
    {
        var mainConnectionString = _postgres.GetConnectionString();

        await using (var conn = new NpgsqlConnection(mainConnectionString))
        {
            await conn.OpenAsync();
            await using var cmd = new NpgsqlCommand("CREATE DATABASE calltype_audit;", conn);
            await cmd.ExecuteNonQueryAsync();
        }

        var auditBuilder = new NpgsqlConnectionStringBuilder(mainConnectionString) { Database = "calltype_audit" };
        return auditBuilder.ConnectionString;
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
    /// with the PREVIOUS time-step and verifies with the CURRENT one so the
    /// two calls consume different steps without a 30s sleep (a step-up code
    /// is single-use per account, see TotpService/MfaEndpoints); this mirrors
    /// how jay_archiver's live E2E helper avoids the same wait.
    /// </summary>
    protected static async Task<string> EnrollAndVerifyMfaAsync(HttpClient client, Guid accountId, string authKey)
    {
        var startResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/start", new { authKey });
        if (startResponse.StatusCode != HttpStatusCode.OK)
            throw new InvalidOperationException(
                $"MFA enroll/start failed with {startResponse.StatusCode}: {await startResponse.Content.ReadAsStringAsync()}");
        var secretBase32 = (await startResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("secretBase32").GetString()!;
        var secret = Base32.Decode(secretBase32);

        var confirmStep = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / TotpService.Period - 1;
        var confirmResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/confirm",
            new { code = TotpService.ComputeCode(secret, confirmStep) });
        if (confirmResponse.StatusCode != HttpStatusCode.OK)
            throw new InvalidOperationException(
                $"MFA enroll/confirm failed with {confirmResponse.StatusCode}: {await confirmResponse.Content.ReadAsStringAsync()}");

        var verifyStep = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / TotpService.Period;
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
        Client.Dispose();
        await Factory.DisposeAsync();
        // Tear down both containers in parallel.
        await Task.WhenAll(
            _postgres.DisposeAsync().AsTask(),
            _azurite.DisposeAsync().AsTask());
    }
}
