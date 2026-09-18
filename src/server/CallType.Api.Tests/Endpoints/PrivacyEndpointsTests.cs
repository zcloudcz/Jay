// ---------------------------------------------------------------------------
// PrivacyEndpointsTests.cs — Integration tests for N09 (GDPR deletion/export)
// ---------------------------------------------------------------------------
// Docker/Testcontainers required (IntegrationTestBase, real Postgres + Azurite).
//
// Uses the same multi-device HttpClient pattern as ChannelEndpointsTests:
// several devices act in one test, each with its own JWT, to avoid the
// documented pitfall that RegisterAndAuthenticateAsync repoints the shared
// Client's Bearer token to the LAST registered device.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Storage.Blobs;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Endpoints;

public class PrivacyEndpointsTests : IntegrationTestBase
{
    private static readonly string AuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    private sealed record TestDevice(Guid DeviceId, string Token, HttpClient Http);

    private async Task<TestDevice> NewDeviceAsync()
    {
        var http = Factory.CreateClient();
        var reg = await http.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06])
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var regBody = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = regBody.GetProperty("deviceId").GetGuid();

        var tokenResponse = await http.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret = regBody.GetProperty("deviceSecret").GetString()
        });
        tokenResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return new TestDevice(deviceId, token, http);
    }

    private async Task<Guid> RegisterAccountAsync(TestDevice device, string? email = null)
    {
        var response = await device.Http.PostAsJsonAsync("/accounts", new
        {
            email = email ?? $"privacy-test-{Guid.NewGuid():N}@example.com",
            authKey = AuthKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetGuid();
        var link = await device.Http.PostAsJsonAsync($"/accounts/{accountId}/devices/{device.DeviceId}", new { authKey = AuthKey });
        link.StatusCode.Should().Be(HttpStatusCode.OK);
        return accountId;
    }

    private async Task<TestDevice> NewOwnerAsync(string? email = null)
    {
        var device = await NewDeviceAsync();
        await RegisterAccountAsync(device, email);
        return device;
    }

    // -----------------------------------------------------------------
    // DELETE /devices/{deviceId}
    // -----------------------------------------------------------------

    [Fact]
    public async Task Delete_device_removes_its_own_row_and_is_idempotent()
    {
        var device = await NewDeviceAsync();

        var first = await device.Http.DeleteAsync($"/devices/{device.DeviceId}");
        first.StatusCode.Should().Be(HttpStatusCode.NoContent);

        // Idempotent — a repeat call is a 404, matching the brief's "already
        // gone -> 404, consistently" rule (auth still succeeds: the JWT itself
        // is still valid until it expires, only the row is gone).
        var second = await device.Http.DeleteAsync($"/devices/{device.DeviceId}");
        second.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Delete_device_is_forbidden_for_a_different_device()
    {
        var victim = await NewDeviceAsync();
        var attacker = await NewDeviceAsync();

        var response = await attacker.Http.DeleteAsync($"/devices/{victim.DeviceId}");
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Devices.AnyAsync(d => d.DeviceId == victim.DeviceId)).Should().BeTrue();
    }

    [Fact]
    public async Task Delete_device_refused_when_device_is_an_organizations_auditor()
    {
        var auditor = await NewDeviceAsync();

        using (var scope = Factory.Services.CreateScope())
        {
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
            org.AuditorDeviceId = auditor.DeviceId;
            auditDb.Organizations.Add(org);
            await auditDb.SaveChangesAsync();
        }

        var response = await auditor.Http.DeleteAsync($"/devices/{auditor.DeviceId}");
        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("device_is_auditor");

        using var verifyScope = Factory.Services.CreateScope();
        var db = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Devices.AnyAsync(d => d.DeviceId == auditor.DeviceId)).Should().BeTrue();
    }

    [Fact]
    public async Task Delete_device_decrements_FollowerCount_of_channels_it_followed()
    {
        var owner = await NewOwnerAsync();
        var createChannel = await owner.Http.PostAsJsonAsync("/channels", new { name = "News", description = "d" });
        createChannel.StatusCode.Should().Be(HttpStatusCode.Created);
        var channelId = (await createChannel.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("channelId").GetGuid();

        var follower = await NewDeviceAsync();
        (await follower.Http.PostAsync($"/channels/{channelId}/follow", null))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var beforeProfile = await owner.Http.GetFromJsonAsync<JsonElement>($"/channels/{channelId}");
        beforeProfile.GetProperty("followerCount").GetInt32().Should().Be(1);

        (await follower.Http.DeleteAsync($"/devices/{follower.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        var afterProfile = await owner.Http.GetFromJsonAsync<JsonElement>($"/channels/{channelId}");
        afterProfile.GetProperty("followerCount").GetInt32().Should().Be(0);
    }

    [Fact]
    public async Task Delete_device_removes_queued_messages_to_and_from_it()
    {
        var sender = await NewDeviceAsync();
        var recipient = await NewDeviceAsync();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.QueuedMessages.Add(new CallType.Api.Models.QueuedMessage
            {
                SenderId = sender.DeviceId, RecipientId = recipient.DeviceId,
                EncryptedBody = [0x01], CreatedAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddDays(30)
            });
            await db.SaveChangesAsync();
        }

        (await recipient.Http.DeleteAsync($"/devices/{recipient.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await verifyDb.QueuedMessages.AnyAsync(m => m.RecipientId == recipient.DeviceId || m.SenderId == recipient.DeviceId))
            .Should().BeFalse();
    }

    // -----------------------------------------------------------------
    // DELETE /accounts/{accountId}
    // -----------------------------------------------------------------

    [Fact]
    public async Task Delete_account_with_wrong_auth_key_is_forbidden_and_deletes_nothing()
    {
        var device = await NewDeviceAsync();
        var accountId = await RegisterAccountAsync(device);

        var wrongKey = Convert.ToBase64String([0xFF, 0xEE, 0xDD]);
        var response = await device.Http.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"/accounts/{accountId}")
        {
            Content = JsonContent.Create(new { authKey = wrongKey })
        });
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Accounts.AnyAsync(a => a.AccountId == accountId)).Should().BeTrue();
    }

    [Fact]
    public async Task Delete_account_of_an_unlinked_device_is_forbidden()
    {
        var other = await NewDeviceAsync();
        var response = await other.Http.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"/accounts/{Guid.NewGuid()}")
        {
            Content = JsonContent.Create(new { authKey = AuthKey })
        });
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Delete_account_removes_account_links_and_backup_blob_but_keeps_the_device()
    {
        var device = await NewOwnerAsync();
        Guid realAccountId;
        {
            using var scope = Factory.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            realAccountId = await db.AccountDevices.Where(ad => ad.DeviceId == device.DeviceId).Select(ad => ad.AccountId).SingleAsync();
        }

        // Upload a real backup so the blob-deletion half of the acceptance
        // criterion ("backup blob really gone from Azurite") is exercised.
        using (var content = new MultipartFormDataContent())
        {
            content.Add(new ByteArrayContent([0x01, 0x02, 0x03]), "file", "backup.enc");
            var upload = await device.Http.PostAsync($"/backups/{realAccountId}", content);
            upload.StatusCode.Should().Be(HttpStatusCode.Created);
        }

        string blobPath;
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            blobPath = await db.Backups.Where(b => b.AccountId == realAccountId).Select(b => b.BlobPath).SingleAsync();
        }

        var delete = await device.Http.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"/accounts/{realAccountId}")
        {
            Content = JsonContent.Create(new { authKey = AuthKey })
        });
        delete.StatusCode.Should().Be(HttpStatusCode.NoContent);

        using var verifyScope = Factory.Services.CreateScope();
        var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await verifyDb.Accounts.AnyAsync(a => a.AccountId == realAccountId)).Should().BeFalse();
        (await verifyDb.AccountDevices.AnyAsync(ad => ad.AccountId == realAccountId)).Should().BeFalse();
        (await verifyDb.Backups.AnyAsync(b => b.AccountId == realAccountId)).Should().BeFalse();
        // The device itself falls back to anonymous — it is NOT deleted.
        (await verifyDb.Devices.AnyAsync(d => d.DeviceId == device.DeviceId)).Should().BeTrue();

        var relativePath = blobPath.StartsWith("backups/") ? blobPath["backups/".Length..] : blobPath;
        var blobClient = verifyScope.ServiceProvider.GetRequiredService<BlobServiceClient>()
            .GetBlobContainerClient("backups").GetBlobClient(relativePath);
        (await blobClient.ExistsAsync()).Value.Should().BeFalse();
    }

    [Fact]
    public async Task Delete_account_refused_when_account_owns_an_organization()
    {
        var owner = await NewOwnerAsync();
        Guid accountId;
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            accountId = await db.AccountDevices.Where(ad => ad.DeviceId == owner.DeviceId).Select(ad => ad.AccountId).SingleAsync();

            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var org = Organization.Create(Guid.NewGuid(), "Acme", accountId, DateTimeOffset.UtcNow);
            auditDb.Organizations.Add(org);
            await auditDb.SaveChangesAsync();
        }

        var response = await owner.Http.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"/accounts/{accountId}")
        {
            Content = JsonContent.Create(new { authKey = AuthKey })
        });
        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("account_owns_organization");

        using var verifyScope = Factory.Services.CreateScope();
        var db2 = verifyScope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db2.Accounts.AnyAsync(a => a.AccountId == accountId)).Should().BeTrue();
    }

    // -----------------------------------------------------------------
    // GET /accounts/{accountId}/export
    // -----------------------------------------------------------------

    [Fact]
    public async Task Export_is_forbidden_for_a_device_not_linked_to_the_account()
    {
        var owner = await NewOwnerAsync();
        Guid accountId;
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            accountId = await db.AccountDevices.Where(ad => ad.DeviceId == owner.DeviceId).Select(ad => ad.AccountId).SingleAsync();
        }

        var stranger = await NewDeviceAsync();
        var response = await stranger.Http.GetAsync($"/accounts/{accountId}/export");
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Export_contains_expected_fields_and_no_secrets()
    {
        var device = await NewOwnerAsync("export-test@example.com");
        Guid accountId;
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            accountId = await db.AccountDevices.Where(ad => ad.DeviceId == device.DeviceId).Select(ad => ad.AccountId).SingleAsync();
            db.Devices.Single(d => d.DeviceId == device.DeviceId).PushToken = "super-secret-fcm-token";
            db.Devices.Single(d => d.DeviceId == device.DeviceId).PushPlatform = "fcm";
            await db.SaveChangesAsync();
        }

        var response = await device.Http.GetAsync($"/accounts/{accountId}/export");
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var raw = await response.Content.ReadAsStringAsync();
        var json = JsonDocument.Parse(raw).RootElement;

        json.GetProperty("account").GetProperty("email").GetString().Should().Be("export-test@example.com");
        json.GetProperty("devices").EnumerateArray().Should().ContainSingle(d =>
            d.GetProperty("deviceId").GetGuid() == device.DeviceId &&
            d.GetProperty("hasPushToken").GetBoolean());

        // Never leaked: the raw auth key hash and the actual push token value.
        raw.Should().NotContain("authKeyHash");
        raw.Should().NotContain("super-secret-fcm-token");
    }
}
