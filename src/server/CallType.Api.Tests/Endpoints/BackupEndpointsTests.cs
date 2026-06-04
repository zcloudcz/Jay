// ---------------------------------------------------------------------------
// BackupEndpointsTests.cs — Integration tests for backup endpoints
// ---------------------------------------------------------------------------
// Tests the backup upload, listing, and download flow against a real PostgreSQL
// instance via Testcontainers. Upload uses multipart form data (IFormFile) to
// Azure Blob Storage (stubbed via BlobServiceClient in the test factory).
//
// The BlobServiceClient is replaced with an Azurite-backed or in-memory mock
// in IntegrationTestBase so tests don't require a real Azure account.
//
// All backup endpoints require JWT — tests authenticate in each test method.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text;
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

    /// <summary>
    /// Helper: creates a multipart form upload request with fake encrypted data.
    /// Simulates what the Flutter client would send as an encrypted backup file.
    /// </summary>
    private static MultipartFormDataContent CreateBackupFileContent(string fileContent = "encrypted-backup-data")
    {
        var content = new MultipartFormDataContent();
        var fileBytes = Encoding.UTF8.GetBytes(fileContent);
        var fileStream = new ByteArrayContent(fileBytes);
        fileStream.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream");
        content.Add(fileStream, "file", "backup.enc");
        return content;
    }

    // -----------------------------------------------------------------------
    // POST /backups/{accountId} — Upload backup
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Upload_backup_returns_created_with_blob_path()
    {
        await RegisterAndAuthenticateAsync();

        // Arrange
        var accountId = await RegisterAccountAsync();
        using var formContent = CreateBackupFileContent();

        // Act
        var response = await Client.PostAsync($"/backups/{accountId}", formContent);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        body.GetProperty("id").GetInt64().Should().BeGreaterThan(0);

        var blobPath = body.GetProperty("blobPath").GetString()!;
        blobPath.Should().StartWith($"backups/{accountId}/");
        blobPath.Should().EndWith(".enc");
    }

    [Fact]
    public async Task Upload_backup_for_nonexistent_account_returns_not_found()
    {
        await RegisterAndAuthenticateAsync();

        // Act — use a random GUID that was never registered as an account
        using var formContent = CreateBackupFileContent();
        var response = await Client.PostAsync($"/backups/{Guid.NewGuid()}", formContent);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Upload_backup_with_empty_file_returns_bad_request()
    {
        await RegisterAndAuthenticateAsync();

        // Arrange
        var accountId = await RegisterAccountAsync();
        using var formContent = CreateBackupFileContent("");

        // Act
        var response = await Client.PostAsync($"/backups/{accountId}", formContent);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // -----------------------------------------------------------------------
    // GET /backups/{accountId} — List backups
    // -----------------------------------------------------------------------

    [Fact]
    public async Task List_backups_returns_ordered_by_date_desc()
    {
        await RegisterAndAuthenticateAsync();

        // Arrange — create two backups for the same account
        var accountId = await RegisterAccountAsync();

        using var first = CreateBackupFileContent("first-backup");
        var firstResp = await Client.PostAsync($"/backups/{accountId}", first);
        firstResp.StatusCode.Should().Be(HttpStatusCode.Created);
        var firstBody = await firstResp.Content.ReadFromJsonAsync<JsonElement>();
        var firstId = firstBody.GetProperty("id").GetInt64();

        using var second = CreateBackupFileContent("second-backup");
        var secondResp = await Client.PostAsync($"/backups/{accountId}", second);
        secondResp.StatusCode.Should().Be(HttpStatusCode.Created);
        var secondBody = await secondResp.Content.ReadFromJsonAsync<JsonElement>();
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
        await RegisterAndAuthenticateAsync();

        var accountId = await RegisterAccountAsync();

        var response = await Client.GetAsync($"/backups/{accountId}");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var backups = await response.Content.ReadFromJsonAsync<JsonElement>();
        backups.GetArrayLength().Should().Be(0);
    }

    // -----------------------------------------------------------------------
    // GET /backups/{accountId}/{backupId} — Download backup
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Download_backup_returns_file_content()
    {
        await RegisterAndAuthenticateAsync();

        // Arrange — upload a backup first
        var accountId = await RegisterAccountAsync();
        var originalContent = "encrypted-backup-payload-for-download-test";
        using var formContent = CreateBackupFileContent(originalContent);
        var uploadResp = await Client.PostAsync($"/backups/{accountId}", formContent);
        uploadResp.StatusCode.Should().Be(HttpStatusCode.Created);
        var uploadBody = await uploadResp.Content.ReadFromJsonAsync<JsonElement>();
        var backupId = uploadBody.GetProperty("id").GetInt64();

        // Act
        var downloadResp = await Client.GetAsync($"/backups/{accountId}/{backupId}");

        // Assert
        downloadResp.StatusCode.Should().Be(HttpStatusCode.OK);
        downloadResp.Content.Headers.ContentType!.MediaType.Should().Be("application/octet-stream");
        var downloadedContent = await downloadResp.Content.ReadAsStringAsync();
        downloadedContent.Should().Be(originalContent);
    }

    [Fact]
    public async Task Download_backup_for_wrong_account_returns_not_found()
    {
        await RegisterAndAuthenticateAsync();

        // Arrange — upload a backup under one account
        var accountId = await RegisterAccountAsync();
        using var formContent = CreateBackupFileContent();
        var uploadResp = await Client.PostAsync($"/backups/{accountId}", formContent);
        uploadResp.StatusCode.Should().Be(HttpStatusCode.Created);
        var uploadBody = await uploadResp.Content.ReadFromJsonAsync<JsonElement>();
        var backupId = uploadBody.GetProperty("id").GetInt64();

        // Act — try to download it under a different account
        var otherAccountId = await RegisterAccountAsync();
        var downloadResp = await Client.GetAsync($"/backups/{otherAccountId}/{backupId}");

        // Assert — should not leak backups across accounts
        downloadResp.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Download_nonexistent_backup_returns_not_found()
    {
        await RegisterAndAuthenticateAsync();
        var accountId = await RegisterAccountAsync();

        var response = await Client.GetAsync($"/backups/{accountId}/999999");

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
