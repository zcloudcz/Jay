// ---------------------------------------------------------------------------
// TurnCredentialEndpointsTests.cs — Integration tests for the TURN endpoint
// ---------------------------------------------------------------------------
// Tests the HTTP layer of the TURN credential API (routing, query param
// validation, response shape). The cryptographic correctness of the
// credential generation itself is covered by TurnCredentialServiceTests.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Endpoints;

public class TurnCredentialEndpointsTests : IntegrationTestBase
{
    [Fact]
    public async Task Get_credentials_returns_valid_response()
    {
        // Arrange — a valid deviceId is required by the endpoint.
        var deviceId = Guid.NewGuid();

        // Act
        var response = await Client.GetAsync($"/turn/credentials?deviceId={deviceId}");

        // Assert — the endpoint should return 200 with all three credential fields.
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();

        // Username format is "{expiry_unix}:{deviceId}" per the TURN shared-secret spec.
        var username = body.GetProperty("username").GetString();
        username.Should().NotBeNullOrEmpty();
        username.Should().Contain(deviceId.ToString(),
            "username must embed the deviceId for TURN server correlation");

        // Credential is a base64-encoded HMAC-SHA1 hash.
        var credential = body.GetProperty("credential").GetString();
        credential.Should().NotBeNullOrEmpty();
        var decodeAction = () => Convert.FromBase64String(credential!);
        decodeAction.Should().NotThrow("credential must be valid base64");

        // TTL must be a positive integer (seconds).
        var ttlSeconds = body.GetProperty("ttlSeconds").GetInt32();
        ttlSeconds.Should().BeGreaterThan(0, "TTL must be positive");
    }

    [Fact]
    public async Task Get_credentials_without_deviceId_returns_bad_request()
    {
        // Act — call the endpoint without any query parameters.
        var response = await Client.GetAsync("/turn/credentials");

        // Assert — the endpoint requires a deviceId. Without it, return 400.
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Get_credentials_with_empty_deviceId_returns_bad_request()
    {
        // Act — pass an empty GUID (all zeros) which the endpoint treats as invalid.
        var response = await Client.GetAsync($"/turn/credentials?deviceId={Guid.Empty}");

        // Assert — Guid.Empty is explicitly rejected because it indicates a
        // missing or uninitialized deviceId on the client side.
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }
}
