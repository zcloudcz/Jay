// ---------------------------------------------------------------------------
// BackupEndpointsTests.cs — Integration tests for backup endpoints
// ---------------------------------------------------------------------------
// Tests the backup creation and listing flow against a real PostgreSQL
// instance via Testcontainers. Verifies account existence checks, input
// validation, blob path format, and list ordering.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class BackupEndpointsTests : IntegrationTestBase
{
    // Reusable valid base64 auth key — same as in AccountEndpointsTests.
    private static readonly string ValidAuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    /// <summary>
    /// Helper: registers an account and returns its accountId.
    /// Backups require an existing account — anonymous devices cannot back up.
    /// </summary>
    private async Task<Guid> RegisterAccountAsync()
    {
        var email = $"backup-test-{Guid.NewGuid():N}@example.com";
        var response = await Client.PostAsJsonAsync("/accounts", new
        {
            email,
            authKey = ValidAuthKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return Guid.Parse(body.GetProperty("accountId").GetString()!);
    }

    // -----------------------------------------------------------------------
    // POST /backups — Create backup
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Create_backup_returns_created_with_blob_path()
    {
        // Arrange
        var accountId = await RegisterAccountAsync();

        // Act
        var response = await Client.PostAsJsonAsync("/backups", new
        {
            accountId,
            sizeBytes = 1024L
        });

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("id").GetInt64().Should().BeGreaterThan(0);

        var blobPath = body.GetProperty("blobPath").GetString()!;
        blobPath.Should().StartWith($"backups/{accountId}/");
        blobPath.Should().EndWith(".enc");
    }

    [Fact]
    public async Task Create_backup_for_nonexistent_account_returns_not_found()
    {
        // Act — use a random GUID that was never registered as an account
        var response = await Client.PostAsJsonAsync("/backups", new
        {
            accountId = Guid.NewGuid(),
            sizeBytes = 512L
        });

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Create_backup_with_zero_size_returns_bad_request()
    {
        // Arrange
        var accountId = await RegisterAccountAsync();

        // Act
        var response = await Client.PostAsJsonAsync("/backups", new
        {
            accountId,
            sizeBytes = 0L
        });

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // -----------------------------------------------------------------------
    // GET /backups/{accountId} — List backups
    // -----------------------------------------------------------------------

    [Fact]
    public async Task List_backups_returns_ordered_by_date_desc()
    {
        // Arrange — create two backups for the same account
        var accountId = await RegisterAccountAsync();

        var first = await Client.PostAsJsonAsync("/backups", new
        {
            accountId,
            sizeBytes = 100L
        });
        first.StatusCode.Should().Be(HttpStatusCode.Created);
        var firstBody = await first.Content.ReadFromJsonAsync<JsonElement>();
        var firstId = firstBody.GetProperty("id").GetInt64();

        var second = await Client.PostAsJsonAsync("/backups", new
        {
            accountId,
            sizeBytes = 200L
        });
        second.StatusCode.Should().Be(HttpStatusCode.Created);
        var secondBody = await second.Content.ReadFromJsonAsync<JsonElement>();
        var secondId = secondBody.GetProperty("id").GetInt64();

        // Act
        var listResponse = await Client.GetAsync($"/backups/{accountId}");

        // Assert
        listResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var backups = await listResponse.Content.ReadFromJsonAsync<JsonElement>();
        backups.GetArrayLength().Should().Be(2);

        // Newest first — the second backup should appear before the first.
        var ids = backups.EnumerateArray()
            .Select(b => b.GetProperty("id").GetInt64())
            .ToList();

        ids[0].Should().Be(secondId, "newest backup should be listed first");
        ids[1].Should().Be(firstId, "oldest backup should be listed last");
    }

    [Fact]
    public async Task List_backups_for_account_with_no_backups_returns_empty()
    {
        var accountId = await RegisterAccountAsync();

        var response = await Client.GetAsync($"/backups/{accountId}");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var backups = await response.Content.ReadFromJsonAsync<JsonElement>();
        backups.GetArrayLength().Should().Be(0);
    }
}
