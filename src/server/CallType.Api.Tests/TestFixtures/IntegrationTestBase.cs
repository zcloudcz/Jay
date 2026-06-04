// ---------------------------------------------------------------------------
// IntegrationTestBase.cs — Shared test infrastructure for integration tests
// ---------------------------------------------------------------------------
// Spins up a real PostgreSQL container via Testcontainers so every test
// class runs against a genuine database — no in-memory fakes that silently
// diverge from PostgreSQL behavior (e.g. case sensitivity, jsonb, arrays).
//
// Implements IAsyncLifetime so xUnit manages the container lifecycle:
//   InitializeAsync  -> start container, build WebApplicationFactory, apply schema
//   DisposeAsync     -> tear down container and factory
//
// Test classes inherit this and get Factory + Client ready to use.
// ---------------------------------------------------------------------------

using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Testcontainers.PostgreSql;
using CallType.Api.Data;

namespace CallType.Api.Tests.TestFixtures;

public abstract class IntegrationTestBase : IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder("postgres:17-alpine")
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

    public async Task InitializeAsync()
    {
        await _postgres.StartAsync();

        Factory = new WebApplicationFactory<Program>()
            .WithWebHostBuilder(builder =>
            {
                // Provide a TURN shared secret for tests — the TurnCredentialService
                // requires it and throws on startup if missing.
                builder.ConfigureAppConfiguration((_, config) =>
                {
                    config.AddInMemoryCollection(new Dictionary<string, string?>
                    {
                        ["Turn:SharedSecret"] = "test-shared-secret-for-turn",
                        ["Turn:TtlSeconds"] = "3600"
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
                });
            });

        Client = Factory.CreateClient();

        // Apply the schema to the fresh database. EnsureCreatedAsync is
        // sufficient here — we don't need migration history tracking in tests.
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.EnsureCreatedAsync();
    }

    public async Task DisposeAsync()
    {
        Client.Dispose();
        await Factory.DisposeAsync();
        await _postgres.DisposeAsync();
    }
}
