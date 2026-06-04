// ---------------------------------------------------------------------------
// AuthEndpointsTests.cs — Integration tests for JWT authentication
// ---------------------------------------------------------------------------
// Tests the full device registration -> token acquisition -> protected
// endpoint access flow. Verifies that:
//   - Device registration now returns a device secret
//   - POST /auth/token issues valid JWTs given correct credentials
//   - POST /auth/refresh issues new JWTs from valid/recently-expired tokens
//   - Protected endpoints reject unauthenticated requests with 401
//   - Public endpoints (health, device registration) remain accessible
//   - SignalR hub rejects unauthenticated connections
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR.Client;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class AuthEndpointsTests : IntegrationTestBase
{
    // Reusable key material for device registration.
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    /// <summary>
    /// Helper: registers a device and returns its deviceId + deviceSecret.
    /// </summary>
    private async Task<(Guid DeviceId, string UserHandle, string DeviceSecret)> RegisterDeviceAsync()
    {
        var response = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return (
            Guid.Parse(body.GetProperty("deviceId").GetString()!),
            body.GetProperty("userHandle").GetString()!,
            body.GetProperty("deviceSecret").GetString()!
        );
    }

    // -----------------------------------------------------------------------
    // Device registration now returns deviceSecret
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Register_device_returns_device_secret()
    {
        // Act — register a new device.
        var response = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });

        // Assert — response must include a base64-encoded device secret.
        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var deviceSecret = body.GetProperty("deviceSecret").GetString();

        deviceSecret.Should().NotBeNullOrEmpty("device registration must return a secret");

        // Verify it is valid base64 and decodes to 32 bytes (256-bit secret).
        var secretBytes = Convert.FromBase64String(deviceSecret!);
        secretBytes.Should().HaveCount(32, "device secret must be 256 bits");
    }

    // -----------------------------------------------------------------------
    // POST /auth/token — Token acquisition
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Get_token_with_valid_credentials_returns_jwt()
    {
        // Arrange — register a device to get credentials.
        var (deviceId, _, deviceSecret) = await RegisterDeviceAsync();

        // Act — exchange device secret for a JWT.
        var response = await Client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret
        });

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var token = body.GetProperty("token").GetString();
        var expiresAt = body.GetProperty("expiresAt").GetString();

        token.Should().NotBeNullOrEmpty("token endpoint must return a JWT");

        // JWT has three dot-separated segments: header.payload.signature.
        token!.Split('.').Should().HaveCount(3, "token must be a valid JWT format");

        expiresAt.Should().NotBeNullOrEmpty("expiration time must be included");
        DateTimeOffset.TryParse(expiresAt, out var expiry).Should().BeTrue();
        expiry.Should().BeAfter(DateTimeOffset.UtcNow, "token should expire in the future");
    }

    [Fact]
    public async Task Get_token_with_wrong_secret_returns_401()
    {
        // Arrange — register a device, then use a different (wrong) secret.
        var (deviceId, _, _) = await RegisterDeviceAsync();
        var wrongSecret = Convert.ToBase64String(new byte[32]); // All zeros — wrong.

        // Act
        var response = await Client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret = wrongSecret
        });

        // Assert — must be 401, not 200. Constant-time comparison prevents timing leaks.
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Get_token_with_nonexistent_device_returns_401()
    {
        // Act — use a random GUID that was never registered.
        var response = await Client.PostAsJsonAsync("/auth/token", new
        {
            deviceId = Guid.NewGuid(),
            deviceSecret = Convert.ToBase64String(new byte[32])
        });

        // Assert — 401, not 404. Intentionally vague to prevent device enumeration.
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    // -----------------------------------------------------------------------
    // Protected endpoint access
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Protected_endpoint_without_token_returns_401()
    {
        // Arrange — register a device so the key-bundle endpoint has a target.
        var (deviceId, _, _) = await RegisterDeviceAsync();

        // Act — hit a protected endpoint WITHOUT an Authorization header.
        // Client starts clean (no auth header set).
        var response = await Client.GetAsync($"/devices/{deviceId}/key-bundle");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Protected_endpoint_with_valid_token_succeeds()
    {
        // Arrange — register, get token, set auth header.
        var (deviceId, _, deviceSecret) = await RegisterDeviceAsync();

        var tokenResponse = await Client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret
        });
        var tokenBody = await tokenResponse.Content.ReadFromJsonAsync<JsonElement>();
        var token = tokenBody.GetProperty("token").GetString()!;

        Client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);

        // Register another device to have something to fetch.
        var otherResponse = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });
        var otherBody = await otherResponse.Content.ReadFromJsonAsync<JsonElement>();
        var otherDeviceId = otherBody.GetProperty("deviceId").GetString()!;

        // Act — hit a protected endpoint with a valid JWT.
        var response = await Client.GetAsync($"/devices/{otherDeviceId}/key-bundle");

        // Assert — should succeed with 200.
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    // -----------------------------------------------------------------------
    // Public endpoints remain accessible
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Health_endpoint_is_public()
    {
        // Act — no auth header at all.
        var response = await Client.GetAsync("/health");

        // Assert — health check must always be accessible.
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Device_registration_is_public()
    {
        // Act — register without any auth header.
        var response = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });

        // Assert — device registration must be publicly accessible (new devices
        // don't have credentials yet).
        response.StatusCode.Should().Be(HttpStatusCode.Created);
    }

    // -----------------------------------------------------------------------
    // SignalR hub authentication
    // -----------------------------------------------------------------------

    [Fact]
    public async Task SignalR_hub_rejects_unauthenticated_connection()
    {
        // Arrange — build a hub connection WITHOUT an access_token.
        var server = Factory.Server;
        await using var connection = new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub", options =>
            {
                options.HttpMessageHandlerFactory = _ => server.CreateHandler();
            })
            .Build();

        // Act & Assert — connecting without a token should throw.
        // The hub has [Authorize], so the server returns 401 during the
        // WebSocket upgrade, which the client sees as a connection failure.
        var act = () => connection.StartAsync();
        await act.Should().ThrowAsync<Exception>(
            "unauthenticated connections to the hub must be rejected");
    }

    // -----------------------------------------------------------------------
    // POST /auth/refresh — Token refresh
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Refresh_token_returns_new_jwt()
    {
        // Arrange — register a device and get a valid token.
        var (deviceId, _, deviceSecret) = await RegisterDeviceAsync();

        var tokenResponse = await Client.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret
        });
        var tokenBody = await tokenResponse.Content.ReadFromJsonAsync<JsonElement>();
        var originalToken = tokenBody.GetProperty("token").GetString()!;

        // Set the token in the Authorization header for the refresh call.
        Client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", originalToken);

        // Act — refresh the token.
        var refreshResponse = await Client.PostAsync("/auth/refresh", null);

        // Assert — should return a new token.
        refreshResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var refreshBody = await refreshResponse.Content.ReadFromJsonAsync<JsonElement>();
        var newToken = refreshBody.GetProperty("token").GetString();

        newToken.Should().NotBeNullOrEmpty("refresh must return a new token");
        // The new token might be the same or different (depends on timing),
        // but it must be a valid JWT.
        newToken!.Split('.').Should().HaveCount(3);
    }
}
