// ---------------------------------------------------------------------------
// SharedContainers.cs - one Postgres + one Azurite for the whole test run
// ---------------------------------------------------------------------------
// xUnit 2 runs IAsyncLifetime per TEST, so IntegrationTestBase used to start
// its own Postgres and Azurite container for each of several hundred tests,
// and most of the suite's wall time was container start-up and contention.
// Instead, both containers are started once (lazily, by the first test that
// needs them) and shared by every test class, which keeps xUnit's cross-class
// parallelism.
//
// Isolation stays per test, exactly as before:
//   * Postgres: the schema is built once into two template databases (main +
//     audit). Every test gets two fresh databases copied from them with
//     CREATE DATABASE ... TEMPLATE and drops them in DisposeAsync, so no test
//     ever sees another test's rows.
//   * Azurite: production code only touches blobs at paths it reads from the
//     (per-test) database, and those are GUID-keyed, so tests sharing one
//     storage account cannot see each other's blobs. Tests that put blobs at
//     fixed names must use unique names (see ChannelPostCleanupServiceTests).
//
// The containers are never disposed explicitly: Testcontainers' resource
// reaper (Ryuk) removes them when the test process exits.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Npgsql;
using Testcontainers.Azurite;
using Testcontainers.PostgreSql;
using CallType.Api.Data;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.TestFixtures;

internal static class SharedContainers
{
    private const string MainTemplate = "calltype_template_main";
    private const string AuditTemplate = "calltype_template_audit";

    private static readonly Lazy<Task<PostgreSqlContainer>> SharedPostgres = new(StartSharedPostgresAsync);
    private static readonly Lazy<Task<AzuriteContainer>> SharedAzurite = new(StartAzuriteAsync);

    /// <summary>
    /// A Postgres container tuned for throwaway test data: no fsync, no
    /// synchronous commit, no full-page writes and the data directory on
    /// tmpfs. None of that changes query results; it only drops durability
    /// that a test database never needs. max_connections leaves room for the
    /// connection pools of every test running in parallel.
    /// </summary>
    internal static PostgreSqlContainer BuildPostgres() =>
        new PostgreSqlBuilder("postgres:17-alpine")
            .WithTmpfsMount("/var/lib/postgresql/data")
            .WithCommand(
                "-c", "fsync=off",
                "-c", "synchronous_commit=off",
                "-c", "full_page_writes=off",
                "-c", "max_connections=500")
            .Build();

    /// <summary>
    /// The container's connection string with generous timeouts. WHY: on the
    /// hosted CI runner many tests start at once, and a busy server could take
    /// longer than Npgsql's default 15 s to accept or answer a connection,
    /// which failed whole tests in their setup (deploy run 42294418106:
    /// "Timeout during reading attempt"). Only the timeouts change, never a
    /// result.
    /// </summary>
    internal static string ConnectionString(PostgreSqlContainer postgres, string? database = null)
    {
        var builder = new NpgsqlConnectionStringBuilder(postgres.GetConnectionString())
        {
            Timeout = 60,
            CommandTimeout = 120,
        };
        if (database is not null)
            builder.Database = database;
        return builder.ConnectionString;
    }

    /// <summary>
    /// Runs a statement that must not run inside a transaction (CREATE/DROP
    /// DATABASE) on the maintenance database, retried like the original
    /// per-test setup: on a loaded runner the first connections can time out.
    /// <paramref name="alreadyDoneState"/> is the SqlState that means an
    /// earlier attempt reached the server before the client gave up.
    /// </summary>
    internal static async Task ExecuteWithRetryAsync(string connectionString, string sql, string? alreadyDoneState)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var conn = new NpgsqlConnection(connectionString);
                await conn.OpenAsync();
                await using var cmd = new NpgsqlCommand(sql, conn);
                await cmd.ExecuteNonQueryAsync();
                return;
            }
            catch (PostgresException e) when (alreadyDoneState is not null && e.SqlState == alreadyDoneState && attempt > 1)
            {
                return;
            }
            catch (Exception e) when (attempt < 5 && e is NpgsqlException or TimeoutException)
            {
                await Task.Delay(TimeSpan.FromSeconds(2 * attempt));
            }
        }
    }

    /// <summary>
    /// Creates a fresh pair of databases (main + audit) for one test, copied
    /// from the schema templates. Returns their connection strings.
    /// </summary>
    public static async Task<(string Main, string Audit)> CreateTestDatabasesAsync()
    {
        var postgres = await SharedPostgres.Value;
        var admin = ConnectionString(postgres);
        var name = $"t_{Guid.NewGuid():N}";

        await ExecuteWithRetryAsync(admin, $"CREATE DATABASE {name} TEMPLATE {MainTemplate};", PostgresErrorCodes.DuplicateDatabase);
        await ExecuteWithRetryAsync(admin, $"CREATE DATABASE {name}_audit TEMPLATE {AuditTemplate};", PostgresErrorCodes.DuplicateDatabase);

        return (ConnectionString(postgres, name), ConnectionString(postgres, $"{name}_audit"));
    }

    /// <summary>
    /// Drops a test's databases. FORCE terminates connections still open in
    /// pools of the disposed factory; the pools are cleared first so idle
    /// client-side connections do not pile up against max_connections.
    /// </summary>
    public static async Task DropTestDatabasesAsync(params string[] connectionStrings)
    {
        var postgres = await SharedPostgres.Value;
        var admin = ConnectionString(postgres);
        foreach (var cs in connectionStrings)
        {
            await using (var conn = new NpgsqlConnection(cs))
                NpgsqlConnection.ClearPool(conn);
            var database = new NpgsqlConnectionStringBuilder(cs).Database;
            await ExecuteWithRetryAsync(admin, $"DROP DATABASE IF EXISTS {database} WITH (FORCE);", null);
        }
    }

    public static async Task<string> AzuriteConnectionStringAsync() =>
        (await SharedAzurite.Value).GetConnectionString();

    private static async Task<PostgreSqlContainer> StartSharedPostgresAsync()
    {
        var postgres = BuildPostgres();
        await postgres.StartAsync();

        var admin = ConnectionString(postgres);
        await ExecuteWithRetryAsync(admin, $"CREATE DATABASE {MainTemplate};", PostgresErrorCodes.DuplicateDatabase);
        await ExecuteWithRetryAsync(admin, $"CREATE DATABASE {AuditTemplate};", PostgresErrorCodes.DuplicateDatabase);

        // Same schema path as before (EnsureCreated, no migration history),
        // with the same UseNpgsql options Program.cs registers. Pooling off so
        // no connection to a template stays open: CREATE DATABASE ... TEMPLATE
        // refuses a source database that has other sessions.
        var mainCs = new NpgsqlConnectionStringBuilder(ConnectionString(postgres, MainTemplate)) { Pooling = false }.ConnectionString;
        await using (var db = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(mainCs).Options))
            await db.Database.EnsureCreatedAsync();

        var auditCs = new NpgsqlConnectionStringBuilder(ConnectionString(postgres, AuditTemplate)) { Pooling = false }.ConnectionString;
        await using (var auditDb = new AuditDbContext(new DbContextOptionsBuilder<AuditDbContext>().UseNpgsql(auditCs).Options))
            await auditDb.Database.EnsureCreatedAsync();

        // Mark them as templates that nobody can connect to, so a stray
        // session cannot block the per-test copies.
        await ExecuteWithRetryAsync(admin, $"ALTER DATABASE {MainTemplate} WITH IS_TEMPLATE true ALLOW_CONNECTIONS false;", null);
        await ExecuteWithRetryAsync(admin, $"ALTER DATABASE {AuditTemplate} WITH IS_TEMPLATE true ALLOW_CONNECTIONS false;", null);

        return postgres;
    }

    // Azurite emulates Azure Blob Storage locally. Backup upload/download
    // tests exercise real blob I/O instead of mocking the BlobServiceClient.
    // skipApiVersionCheck is required because Azure.Storage.Blobs SDK v12.28+
    // uses API version 2026-04-06 which the latest Azurite image doesn't yet
    // recognize. The flag tells Azurite to accept any API version.
    // inMemoryPersistence: blobs only live for the test run anyway.
    private static async Task<AzuriteContainer> StartAzuriteAsync()
    {
        var azurite = new AzuriteBuilder("mcr.microsoft.com/azure-storage/azurite:latest")
            .WithCommand("--skipApiVersionCheck", "--inMemoryPersistence")
            .Build();
        await azurite.StartAsync();
        return azurite;
    }
}
