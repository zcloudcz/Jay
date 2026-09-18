// ---------------------------------------------------------------------------
// BusinessModeIntegrationTests.cs — E00 foundation: two databases, two roles
// ---------------------------------------------------------------------------
// Proves (a) the API starts successfully with both the Delivery and Audit
// databases configured (business mode enabled), and (b) the production role
// model in infra/postgres/audit-roles.sql actually blocks UPDATE/DELETE on
// audit tables — the entire point of KB3's append-only guarantee.
//
// Requires Docker (Testcontainers), like every IntegrationTestBase test.
// ---------------------------------------------------------------------------

using System.Net;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using CallType.Audit.Application;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Audit;

public class BusinessModeIntegrationTests : IntegrationTestBase
{
    [Fact]
    public async Task Api_starts_with_both_delivery_and_audit_databases_configured()
    {
        var response = await Client.GetAsync("/health");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Audit_app_role_cannot_update_or_delete_audit_records()
    {
        // Seed one AuditRecord using the (privileged, test-only) EF connection.
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            db.Add(new AuditRecord(
                organizationId: Guid.NewGuid(),
                groupId: Guid.NewGuid(),
                messageId: Guid.NewGuid(),
                senderDeviceId: Guid.NewGuid(),
                sentAt: DateTimeOffset.UtcNow,
                archivedAt: DateTimeOffset.UtcNow,
                kind: "text",
                sizeBytes: 10,
                contentHash: new byte[32],
                ciphertextForArchive: null,
                sequence: 1,
                prevHash: HashChain.Genesis,
                hash: new byte[32]));
            await db.SaveChangesAsync();
        }

        // Apply the production role model against this same (test) audit database.
        const string appPassword = "test-only-app-password";
        await ApplyAuditRolesScriptAsync(appPassword);

        var appConnectionString = new NpgsqlConnectionStringBuilder(AuditConnectionString)
        {
            Username = "calltype_audit_app",
            Password = appPassword
        }.ConnectionString;

        await using var appConn = new NpgsqlConnection(appConnectionString);
        await appConn.OpenAsync();

        var updateAttempt = async () =>
        {
            await using var cmd = new NpgsqlCommand("UPDATE \"AuditRecords\" SET \"Kind\" = 'tampered';", appConn);
            await cmd.ExecuteNonQueryAsync();
        };

        await updateAttempt.Should().ThrowAsync<PostgresException>()
            .Where(e => e.SqlState == PostgresErrorCodes.InsufficientPrivilege);

        var deleteAttempt = async () =>
        {
            await using var cmd = new NpgsqlCommand("DELETE FROM \"AuditRecords\";", appConn);
            await cmd.ExecuteNonQueryAsync();
        };

        await deleteAttempt.Should().ThrowAsync<PostgresException>()
            .Where(e => e.SqlState == PostgresErrorCodes.InsufficientPrivilege);
    }

    /// <summary>
    /// Applies infra/postgres/audit-roles.sql verbatim (with the placeholder
    /// passwords substituted) against the test's Audit database, exactly as
    /// an ops runbook would against production — this is what actually
    /// proves the checked-in script does what its comments claim.
    /// </summary>
    private async Task ApplyAuditRolesScriptAsync(string appPassword)
    {
        var scriptPath = Path.Combine(FindRepoRoot(), "infra", "postgres", "audit-roles.sql");
        var script = await File.ReadAllTextAsync(scriptPath);
        script = script.Replace("REPLACE_ME_OPS", "test-only-ops-password")
                        .Replace("REPLACE_ME", appPassword);

        await using var conn = new NpgsqlConnection(AuditConnectionString);
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
}
