// ---------------------------------------------------------------------------
// DeviceEndpointsTests.cs — Integration tests for device registration and
//                            key bundle endpoints
// ---------------------------------------------------------------------------
// Runs against a real PostgreSQL instance via Testcontainers so we test the
// full stack: HTTP routing → JSON binding → EF Core → Npgsql → PostgreSQL.
// This catches issues that in-memory fakes silently hide (unique index
// enforcement, byte[] round-tripping, cascade deletes).
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using ZMessanger.Api.Data;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Endpoints;

public class DeviceEndpointsTests : IntegrationTestBase
{
    // Reusable valid base64 key material for tests that don't care about
    // the actual key content — just need something that passes validation.
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    // The handle format: "ZM-" prefix, two groups of 4 uppercase alphanumeric chars.
    private static readonly Regex HandlePattern = new(@"^ZM-[A-Z0-9]{4}-[A-Z0-9]{4}$");

    // -----------------------------------------------------------------------
    // POST /devices
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Register_device_returns_created_with_handle()
    {
        // Arrange
        var request = new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        };

        // Act
        var response = await Client.PostAsJsonAsync("/devices", request);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = body.GetProperty("deviceId").GetString();
        var userHandle = body.GetProperty("userHandle").GetString();

        deviceId.Should().NotBeNullOrEmpty();
        Guid.TryParse(deviceId, out _).Should().BeTrue("deviceId must be a valid GUID");
        userHandle.Should().MatchRegex(HandlePattern, "handle must match ZM-XXXX-XXXX format");

        // Verify the Location header points to the new device resource.
        response.Headers.Location!.ToString().Should().Contain($"/devices/{deviceId}");
    }

    [Fact]
    public async Task Register_device_without_keys_returns_bad_request()
    {
        // Arrange — empty keys should be rejected
        var request = new
        {
            identityKey = "",
            signedPreKey = ""
        };

        // Act
        var response = await Client.PostAsJsonAsync("/devices", request);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Register_device_with_null_keys_returns_bad_request()
    {
        // Arrange — null/missing keys
        var request = new { };

        // Act
        var response = await Client.PostAsJsonAsync("/devices", request);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Register_device_with_invalid_base64_returns_bad_request()
    {
        // Arrange — "not-base64!!!" is not valid base64
        var request = new
        {
            identityKey = "not-base64!!!",
            signedPreKey = ValidSignedPreKey
        };

        // Act
        var response = await Client.PostAsJsonAsync("/devices", request);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Register_device_stores_all_one_time_pre_keys()
    {
        // Arrange — register with 5 one-time pre-keys
        var otks = Enumerable.Range(1, 5).Select(i => new
        {
            keyId = i,
            publicKey = Convert.ToBase64String(new byte[] { (byte)(0x10 + i) })
        }).ToList();

        var request = new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey,
            oneTimePreKeys = otks
        };

        // Act
        var response = await Client.PostAsJsonAsync("/devices", request);
        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = Guid.Parse(body.GetProperty("deviceId").GetString()!);

        // Assert — verify all 5 OTKs were stored by consuming them one at a time.
        // Each key-bundle fetch should return a different OTK until exhausted.
        var consumedKeyIds = new HashSet<int>();
        for (var i = 0; i < 5; i++)
        {
            var bundleResponse = await Client.GetAsync($"/devices/{deviceId}/key-bundle");
            bundleResponse.StatusCode.Should().Be(HttpStatusCode.OK);

            var bundle = await bundleResponse.Content.ReadFromJsonAsync<JsonElement>();
            var otkElement = bundle.GetProperty("oneTimePreKey");
            otkElement.ValueKind.Should().NotBe(JsonValueKind.Null,
                $"OTK #{i + 1} should still be available (5 uploaded, {i} consumed)");
            consumedKeyIds.Add(otkElement.GetProperty("keyId").GetInt32());
        }

        // All 5 keys should have been consumed (each unique).
        consumedKeyIds.Should().HaveCount(5);

        // Sixth fetch should return null for oneTimePreKey — all consumed.
        var finalResponse = await Client.GetAsync($"/devices/{deviceId}/key-bundle");
        var finalBundle = await finalResponse.Content.ReadFromJsonAsync<JsonElement>();
        finalBundle.GetProperty("oneTimePreKey").ValueKind.Should().Be(JsonValueKind.Null);
    }

    // -----------------------------------------------------------------------
    // GET /devices/{id}/key-bundle
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Get_key_bundle_returns_keys_and_consumes_one_time_key()
    {
        // Arrange — register a device with exactly 1 OTK
        var request = new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey,
            oneTimePreKeys = new[]
            {
                new { keyId = 42, publicKey = Convert.ToBase64String([0xAA, 0xBB]) }
            }
        };

        var registerResponse = await Client.PostAsJsonAsync("/devices", request);
        registerResponse.StatusCode.Should().Be(HttpStatusCode.Created);

        var regBody = await registerResponse.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = regBody.GetProperty("deviceId").GetString()!;

        // Act — first fetch: should include the OTK
        var firstResponse = await Client.GetAsync($"/devices/{deviceId}/key-bundle");

        // Assert
        firstResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var firstBundle = await firstResponse.Content.ReadFromJsonAsync<JsonElement>();
        firstBundle.GetProperty("deviceId").GetString().Should().Be(deviceId);
        firstBundle.GetProperty("identityKey").GetString().Should().Be(ValidIdentityKey);
        firstBundle.GetProperty("signedPreKey").GetString().Should().Be(ValidSignedPreKey);

        var firstOtk = firstBundle.GetProperty("oneTimePreKey");
        firstOtk.ValueKind.Should().NotBe(JsonValueKind.Null, "first fetch should include the OTK");
        firstOtk.GetProperty("keyId").GetInt32().Should().Be(42);
        firstOtk.GetProperty("publicKey").GetString()
            .Should().Be(Convert.ToBase64String([0xAA, 0xBB]));

        // Act — second fetch: OTK should be consumed (null)
        var secondResponse = await Client.GetAsync($"/devices/{deviceId}/key-bundle");
        var secondBundle = await secondResponse.Content.ReadFromJsonAsync<JsonElement>();

        secondBundle.GetProperty("oneTimePreKey").ValueKind.Should().Be(JsonValueKind.Null,
            "second fetch should return null — the only OTK was already consumed");

        // Identity and signed pre-keys should still be present.
        secondBundle.GetProperty("identityKey").GetString().Should().Be(ValidIdentityKey);
        secondBundle.GetProperty("signedPreKey").GetString().Should().Be(ValidSignedPreKey);
    }

    [Fact]
    public async Task Get_key_bundle_for_nonexistent_device_returns_404()
    {
        // Act — use a random GUID that won't exist in the database
        var response = await Client.GetAsync($"/devices/{Guid.NewGuid()}/key-bundle");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Get_key_bundle_without_one_time_keys_returns_null_otk()
    {
        // Arrange — register a device WITHOUT any OTKs
        var request = new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        };

        var registerResponse = await Client.PostAsJsonAsync("/devices", request);
        var regBody = await registerResponse.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = regBody.GetProperty("deviceId").GetString()!;

        // Act
        var response = await Client.GetAsync($"/devices/{deviceId}/key-bundle");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var bundle = await response.Content.ReadFromJsonAsync<JsonElement>();
        bundle.GetProperty("oneTimePreKey").ValueKind.Should().Be(JsonValueKind.Null);
    }

    [Fact]
    public async Task Register_two_devices_get_different_handles()
    {
        // Verifies handle uniqueness — two registrations should never
        // produce the same handle (probabilistically guaranteed by the
        // random generation + DB unique index).
        var request = new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        };

        var response1 = await Client.PostAsJsonAsync("/devices", request);
        var response2 = await Client.PostAsJsonAsync("/devices", request);

        var body1 = await response1.Content.ReadFromJsonAsync<JsonElement>();
        var body2 = await response2.Content.ReadFromJsonAsync<JsonElement>();

        var handle1 = body1.GetProperty("userHandle").GetString();
        var handle2 = body2.GetProperty("userHandle").GetString();

        handle1.Should().NotBe(handle2, "two devices should get different handles");
    }
}
