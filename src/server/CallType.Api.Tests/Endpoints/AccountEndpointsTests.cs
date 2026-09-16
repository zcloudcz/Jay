// ---------------------------------------------------------------------------
// AccountEndpointsTests.cs — Integration tests for account endpoints
// ---------------------------------------------------------------------------
// Tests the full registration -> login -> device-linking flow against a real
// PostgreSQL instance via Testcontainers. Verifies Argon2id hashing, email
// uniqueness, timing-safe comparison, and device linkage.
//
// POST /accounts and POST /accounts/login are public (AllowAnonymous).
// Device linking and listing require JWT — tests authenticate first.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class AccountEndpointsTests : IntegrationTestBase
{
    // Reusable valid base64 auth key — simulates the high-entropy key derived
    // client-side from the user's passphrase via a KDF.
    private static readonly string ValidAuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    // Reusable key material for device registration helper.
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    /// <summary>
    /// Helper: registers a device and returns its deviceId. Many account tests
    /// need a device to link, so this avoids repetitive setup code.
    /// </summary>
    private async Task<Guid> RegisterDeviceAsync()
    {
        var response = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return Guid.Parse(body.GetProperty("deviceId").GetString()!);
    }

    /// <summary>
    /// Helper: registers an account and returns its accountId.
    /// </summary>
    private async Task<Guid> RegisterAccountAsync(string email, string? authKey = null)
    {
        var response = await Client.PostAsJsonAsync("/accounts", new
        {
            email,
            authKey = authKey ?? ValidAuthKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return Guid.Parse(body.GetProperty("accountId").GetString()!);
    }

    // -----------------------------------------------------------------------
    // POST /accounts + POST /accounts/login — Registration and login
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Register_and_login_roundtrip_succeeds()
    {
        // Arrange — register an account
        var email = $"test-{Guid.NewGuid():N}@example.com";
        var registerResponse = await Client.PostAsJsonAsync("/accounts", new
        {
            email,
            authKey = ValidAuthKey
        });

        // Assert registration
        registerResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var regBody = await registerResponse.Content.ReadFromJsonAsync<JsonElement>();
        var accountId = regBody.GetProperty("accountId").GetString();
        accountId.Should().NotBeNullOrEmpty();
        Guid.TryParse(accountId, out _).Should().BeTrue("accountId must be a valid GUID");

        // Act — login with same credentials
        var loginResponse = await Client.PostAsJsonAsync("/accounts/login", new
        {
            email,
            authKey = ValidAuthKey
        });

        // Assert login
        loginResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var loginBody = await loginResponse.Content.ReadFromJsonAsync<JsonElement>();
        loginBody.GetProperty("accountId").GetString().Should().Be(accountId,
            "login should return the same accountId as registration");
    }

    [Fact]
    public async Task Login_with_wrong_key_returns_401()
    {
        // Arrange — register with one key, try to login with a different one.
        var email = $"test-{Guid.NewGuid():N}@example.com";
        await Client.PostAsJsonAsync("/accounts", new
        {
            email,
            authKey = ValidAuthKey
        });

        var wrongKey = Convert.ToBase64String(
            [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8,
             0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF1, 0xF0]);

        // Act
        var loginResponse = await Client.PostAsJsonAsync("/accounts/login", new
        {
            email,
            authKey = wrongKey
        });

        // Assert — should be 401, NOT 200. If this fails, Argon2id comparison is broken.
        loginResponse.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Login_with_nonexistent_email_returns_401()
    {
        // Act — login with an email that was never registered
        var loginResponse = await Client.PostAsJsonAsync("/accounts/login", new
        {
            email = "nobody@example.com",
            authKey = ValidAuthKey
        });

        // Assert — 401, not 404. We intentionally don't reveal whether the email exists
        // to prevent user enumeration attacks.
        loginResponse.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Duplicate_email_returns_409_conflict()
    {
        // Arrange — register an account
        var email = $"test-{Guid.NewGuid():N}@example.com";
        var firstResponse = await Client.PostAsJsonAsync("/accounts", new
        {
            email,
            authKey = ValidAuthKey
        });
        firstResponse.StatusCode.Should().Be(HttpStatusCode.Created);

        // Act — try to register the same email again
        var secondResponse = await Client.PostAsJsonAsync("/accounts", new
        {
            email,
            authKey = ValidAuthKey
        });

        // Assert
        secondResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Register_with_empty_email_returns_bad_request()
    {
        var response = await Client.PostAsJsonAsync("/accounts", new
        {
            email = "",
            authKey = ValidAuthKey
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Register_with_empty_auth_key_returns_bad_request()
    {
        var response = await Client.PostAsJsonAsync("/accounts", new
        {
            email = "test@example.com",
            authKey = ""
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Register_with_invalid_email_format_returns_bad_request()
    {
        // "notanemail" lacks an '@' and domain — the server uses MailAddress
        // parsing to catch obviously malformed emails before hitting the DB.
        var response = await Client.PostAsJsonAsync("/accounts", new
        {
            email = "notanemail",
            authKey = ValidAuthKey
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // -----------------------------------------------------------------------
    // POST /accounts/{accountId}/devices/{deviceId} — Link device to account
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Link_own_device_with_proof_is_idempotent_and_lists_device()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var accountId = await RegisterAccountAsync($"test-{Guid.NewGuid():N}@example.com");
        for (var i = 0; i < 2; i++)
        {
            var response = await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey });
            response.StatusCode.Should().Be(HttpStatusCode.OK);
        }
        var list = await Client.GetAsync($"/accounts/{accountId}/devices");
        list.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await list.Content.ReadFromJsonAsync<JsonElement>();
        body.GetArrayLength().Should().Be(1);
        body[0].GetProperty("deviceId").GetGuid().Should().Be(deviceId);
    }

    [Fact]
    public async Task Link_without_correct_account_proof_is_forbidden()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var accountId = await RegisterAccountAsync($"test-{Guid.NewGuid():N}@example.com");
        var response = await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = Convert.ToBase64String(new byte[32]) });
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Client.GetAsync($"/accounts/{accountId}/devices")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Link_another_device_even_with_account_proof_is_forbidden()
    {
        await RegisterAndAuthenticateAsync();
        var otherDevice = await RegisterDeviceAsync();
        var accountId = await RegisterAccountAsync($"test-{Guid.NewGuid():N}@example.com");
        var response = await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{otherDevice}", new { authKey = ValidAuthKey });
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Link_nonexistent_account_returns_not_found()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var response = await Client.PostAsJsonAsync($"/accounts/{Guid.NewGuid()}/devices/{deviceId}", new { authKey = ValidAuthKey });
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
