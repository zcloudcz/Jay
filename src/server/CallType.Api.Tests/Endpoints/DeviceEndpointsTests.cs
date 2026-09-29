// ---------------------------------------------------------------------------
// DeviceEndpointsTests.cs — Integration tests for device registration and
//                            key bundle endpoints
// ---------------------------------------------------------------------------
// Runs against a real PostgreSQL instance via Testcontainers so we test the
// full stack: HTTP routing -> JSON binding -> EF Core -> Npgsql -> PostgreSQL.
// This catches issues that in-memory fakes silently hide (unique index
// enforcement, byte[] round-tripping, cascade deletes).
//
// POST /devices is public (AllowAnonymous) — no auth needed.
// GET /devices/{id}/key-bundle requires JWT — tests authenticate first.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class DeviceEndpointsTests : IntegrationTestBase
{
    // Reusable valid base64 key material for tests that don't care about
    // the actual key content — just need something that passes validation.
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    // The handle format: "CT-" prefix, two groups of 4 chars from the reduced
    // alphabet (excludes ambiguous 0, O, 1, I, L to reduce transcription errors).
    private static readonly Regex HandlePattern = new(@"^CT-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$");

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
        userHandle.Should().MatchRegex(HandlePattern, "handle must match CT-XXXX-XXXX format");

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
        // Authenticate first — key-bundle endpoint requires JWT.
        await RegisterAndAuthenticateAsync();

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
        // Authenticate — key-bundle endpoint requires JWT.
        await RegisterAndAuthenticateAsync();

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
        // Authenticate — key-bundle endpoint requires JWT.
        await RegisterAndAuthenticateAsync();

        // Act — use a random GUID that won't exist in the database
        var response = await Client.GetAsync($"/devices/{Guid.NewGuid()}/key-bundle");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Get_key_bundle_without_one_time_keys_returns_null_otk()
    {
        // Authenticate — key-bundle endpoint requires JWT.
        await RegisterAndAuthenticateAsync();

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
    public async Task Register_device_with_invalid_otk_base64_returns_bad_request()
    {
        // Valid identity/signed keys but the one-time pre-key has garbage base64.
        // The server must validate OTK key material, not just the top-level keys.
        var request = new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey,
            oneTimePreKeys = new[]
            {
                new { keyId = 1, publicKey = "!!!not-valid-base64!!!" }
            }
        };

        var response = await Client.PostAsJsonAsync("/devices", request);

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // -----------------------------------------------------------------------
    // PUT /devices/{id}/push-token
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Update_push_token_stores_fcm_token()
    {
        // Arrange — register and authenticate a device.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        // Act — set a push token for the device.
        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "fcm-test-token-abc123",
            platform = "fcm"
        });

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NoContent);

        // Verify the token was stored in the database.
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var device = await db.Devices.FirstAsync(d => d.DeviceId == deviceId);

        device.PushToken.Should().Be("fcm-test-token-abc123");
        device.PushPlatform.Should().Be("fcm");
    }

    [Fact]
    public async Task Update_push_token_stores_apns_token()
    {
        // Verify APNs tokens are accepted alongside FCM.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "apns-device-token-hex-string",
            platform = "apns"
        });

        response.StatusCode.Should().Be(HttpStatusCode.NoContent);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var device = await db.Devices.FirstAsync(d => d.DeviceId == deviceId);

        device.PushToken.Should().Be("apns-device-token-hex-string");
        device.PushPlatform.Should().Be("apns");
    }

    [Fact]
    public async Task Update_push_token_replaces_previous_token()
    {
        // When the FCM token refreshes, the client sends the new token.
        // The old token should be overwritten — not appended.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        // Set initial token.
        await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "old-token",
            platform = "fcm"
        });

        // Replace with new token.
        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "new-token",
            platform = "fcm"
        });

        response.StatusCode.Should().Be(HttpStatusCode.NoContent);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var device = await db.Devices.FirstAsync(d => d.DeviceId == deviceId);

        device.PushToken.Should().Be("new-token", "the latest token should replace the previous one");
    }

    [Fact]
    public async Task Update_push_token_with_invalid_platform_returns_bad_request()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "some-token",
            platform = "webpush" // Not a recognized platform.
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Update_push_token_with_empty_token_returns_bad_request()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "",
            platform = "fcm"
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Update_push_token_for_another_device_id_returns_403_device_mismatch()
    {
        // X0 IDOR fix: before, any authenticated device could redirect another
        // device's push wake-ups (and previously got 404 only for unknown ids).
        var (victimId, _, _) = await RegisterAndAuthenticateAsync();
        await RegisterAndAuthenticateAsync(); // Client now speaks as the attacker

        foreach (var target in new[] { victimId, Guid.NewGuid() })
        {
            var response = await Client.PutAsJsonAsync($"/devices/{target}/push-token", new
            {
                token = "attacker-token",
                platform = "fcm"
            });

            response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
            (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
                .Should().Be("device_mismatch");
        }

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Devices.SingleAsync(d => d.DeviceId == victimId)).PushToken.Should().BeNull();
    }

    [Fact]
    public async Task Delete_push_token_for_another_device_returns_403_and_keeps_its_token()
    {
        var (victimId, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{victimId}/push-token", new { token = "victim-token", platform = "fcm" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        await RegisterAndAuthenticateAsync();

        var response = await Client.DeleteAsync($"/devices/{victimId}/push-token?platform=fcm");

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("device_mismatch");
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Devices.SingleAsync(d => d.DeviceId == victimId)).PushToken.Should().Be("victim-token");
    }

    [Fact]
    public async Task Apns_voip_token_goes_to_its_own_slot_and_keeps_the_alert_token()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new { token = "apns-alert-token", platform = "apns" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token", new
        {
            token = "abcdef0123456789",
            platform = "apns-voip",
            environment = "sandbox"
        });

        response.StatusCode.Should().Be(HttpStatusCode.NoContent);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var device = await db.Devices.SingleAsync(d => d.DeviceId == deviceId);
        device.VoipPushToken.Should().Be("abcdef0123456789");
        device.VoipPushEnvironment.Should().Be("sandbox");
        device.PushToken.Should().Be("apns-alert-token", "a PushKit registration must not overwrite the alert token");
        device.PushPlatform.Should().Be("apns", "apns-voip is never stored in PushPlatform");
        device.PushTokenUpdatedAt.Should().NotBeNull();
    }

    [Fact]
    public async Task Push_key_is_stored_with_any_platform_and_kept_when_omitted()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();

        (await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token",
            new { token = "fcm-token", platform = "fcm", pushKey = Convert.ToBase64String(key) }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token",
            new { token = "fcm-token-2", platform = "fcm" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var device = await db.Devices.SingleAsync(d => d.DeviceId == deviceId);
        device.PushKey.Should().Equal(key);
        device.PushToken.Should().Be("fcm-token-2");
    }

    [Theory]
    [InlineData("fcm", "t", null, "AAAA", "invalid_push_key")]           // 3 bytes
    [InlineData("fcm", "t", null, "not base64!", "invalid_push_key")]
    [InlineData("apns", "t", "staging", null, "invalid_environment")]
    [InlineData("webpush", "t", null, null, "invalid_platform")]
    [InlineData("fcm", "", null, null, "invalid_token")]
    public async Task Invalid_push_token_request_returns_400_with_code(
        string platform, string token, string? environment, string? pushKey, string expectedCode)
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token",
            new { token, platform, environment, pushKey });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be(expectedCode);
    }

    [Fact]
    public async Task Token_longer_than_512_characters_is_rejected()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token",
            new { token = new string('a', 513), platform = "fcm" });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
            .Should().Be("invalid_token");
    }

    [Fact]
    public async Task Delete_push_token_clears_only_the_named_slot_and_is_idempotent()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token",
            new { token = "fcm-token", platform = "fcm", pushKey = Convert.ToBase64String(new byte[32]) }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await Client.PutAsJsonAsync($"/devices/{deviceId}/push-token",
            new { token = "voip-token", platform = "apns-voip", environment = "production" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await Client.DeleteAsync($"/devices/{deviceId}/push-token?platform=apns-voip"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using (var scope = Factory.Services.CreateScope())
        {
            var device = await scope.ServiceProvider.GetRequiredService<AppDbContext>()
                .Devices.SingleAsync(d => d.DeviceId == deviceId);
            device.VoipPushToken.Should().BeNull();
            device.VoipPushEnvironment.Should().BeNull();
            device.PushToken.Should().Be("fcm-token");
            device.PushKey.Should().NotBeNull("dropping the VoIP slot keeps the key the alert channel uses");
        }

        // fcm clears the alert slot AND the hint key; a second delete is still 204.
        (await Client.DeleteAsync($"/devices/{deviceId}/push-token?platform=fcm"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await Client.DeleteAsync($"/devices/{deviceId}/push-token?platform=fcm"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using (var scope = Factory.Services.CreateScope())
        {
            var device = await scope.ServiceProvider.GetRequiredService<AppDbContext>()
                .Devices.SingleAsync(d => d.DeviceId == deviceId);
            device.PushToken.Should().BeNull();
            device.PushPlatform.Should().BeNull();
            device.PushKey.Should().BeNull();
        }
    }

    [Fact]
    public async Task Delete_push_token_without_a_valid_platform_returns_400()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        foreach (var url in new[] { $"/devices/{deviceId}/push-token", $"/devices/{deviceId}/push-token?platform=sms" })
        {
            var response = await Client.DeleteAsync(url);
            response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString()
                .Should().Be("invalid_platform");
        }
    }

    [Fact]
    public async Task Update_push_token_without_auth_returns_unauthorized()
    {
        // The push-token endpoint requires authentication. Verify a raw
        // (unauthenticated) client gets 401.
        using var unauthenticatedClient = Factory.CreateClient();

        var response = await unauthenticatedClient.PutAsJsonAsync(
            $"/devices/{Guid.NewGuid()}/push-token",
            new { token = "some-token", platform = "fcm" });

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    // -----------------------------------------------------------------------
    // Handle uniqueness
    // -----------------------------------------------------------------------

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
    [Fact]
    public async Task Signed_bundle_and_handle_lookup_roundtrip_without_consuming_prekeys()
    {
        await RegisterAndAuthenticateAsync();
        var signingKey = Convert.ToBase64String(new byte[32]);
        var signature = Convert.ToBase64String(new byte[64]);
        var response = await Client.PostAsJsonAsync("/devices", new {
            identityKey = Convert.ToBase64String(new byte[32]),
            signedPreKey = Convert.ToBase64String(new byte[32]), signingKey, signature,
            oneTimePreKeys = new[] { new { keyId = 1, publicKey = Convert.ToBase64String(new byte[32]) } }
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var id = body.GetProperty("deviceId").GetGuid();
        var handle = body.GetProperty("userHandle").GetString();
        var lookup = await Client.GetAsync($"/devices/by-handle/{handle}");
        lookup.StatusCode.Should().Be(HttpStatusCode.OK);
        var found = await lookup.Content.ReadFromJsonAsync<JsonElement>();
        found.GetProperty("deviceId").GetGuid().Should().Be(id);
        // Exactly deviceId + userHandle + isBot — lookup must not leak anything else.
        found.EnumerateObject().Should().HaveCount(3);
        var bundleResponse = await Client.GetAsync($"/devices/{id}/key-bundle");
        var bundle = await bundleResponse.Content.ReadFromJsonAsync<JsonElement>();
        bundle.GetProperty("signingKey").GetString().Should().Be(signingKey);
        bundle.GetProperty("signature").GetString().Should().Be(signature);
        bundle.GetProperty("oneTimePreKey").GetProperty("keyId").GetInt32().Should().Be(1);
    }

    [Fact]
    public async Task Registration_rejects_incomplete_signing_bundle()
    {
        var response = await Client.PostAsJsonAsync("/devices", new {
            identityKey = ValidIdentityKey, signedPreKey = ValidSignedPreKey,
            signingKey = Convert.ToBase64String(new byte[32])
        });
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // -----------------------------------------------------------------------
    // isBot — self-declared at registration, immutable afterwards
    // -----------------------------------------------------------------------

    /// <summary>Registers a device with an optional isBot flag and returns its id + handle.</summary>
    private async Task<(Guid DeviceId, string Handle)> RegisterDeviceAsync(bool? isBot)
    {
        // isBot is omitted entirely when null to exercise the "old client" path.
        object request = isBot is null
            ? new { identityKey = ValidIdentityKey, signedPreKey = ValidSignedPreKey }
            : new { identityKey = ValidIdentityKey, signedPreKey = ValidSignedPreKey, isBot };
        var response = await Client.PostAsJsonAsync("/devices", request);
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return (body.GetProperty("deviceId").GetGuid(), body.GetProperty("userHandle").GetString()!);
    }

    private async Task<bool> GetIsBotFromKeyBundleAsync(Guid deviceId)
    {
        var bundle = await (await Client.GetAsync($"/devices/{deviceId}/key-bundle"))
            .Content.ReadFromJsonAsync<JsonElement>();
        return bundle.GetProperty("isBot").GetBoolean();
    }

    private async Task<bool> GetIsBotFromLookupAsync(string handle)
    {
        var found = await (await Client.GetAsync($"/devices/by-handle/{handle}"))
            .Content.ReadFromJsonAsync<JsonElement>();
        return found.GetProperty("isBot").GetBoolean();
    }

    [Fact]
    public async Task Bot_registration_is_visible_in_key_bundle_and_handle_lookup()
    {
        await RegisterAndAuthenticateAsync();
        var (id, handle) = await RegisterDeviceAsync(isBot: true);

        // Both places a client looks at BEFORE adding a contact must show the flag.
        (await GetIsBotFromKeyBundleAsync(id)).Should().BeTrue();
        (await GetIsBotFromLookupAsync(handle)).Should().BeTrue();
    }

    [Fact]
    public async Task Device_registered_without_isBot_is_not_a_bot()
    {
        // Existing clients do not send the field at all — they must stay humans.
        await RegisterAndAuthenticateAsync();
        var (id, handle) = await RegisterDeviceAsync(isBot: null);

        (await GetIsBotFromKeyBundleAsync(id)).Should().BeFalse();
        (await GetIsBotFromLookupAsync(handle)).Should().BeFalse();
    }

    [Fact]
    public async Task IsBot_cannot_be_changed_after_registration()
    {
        // Client speaks as a human device (RegisterAndAuthenticateAsync never sets isBot).
        var (humanId, _, _) = await RegisterAndAuthenticateAsync();
        var (botId, _) = await RegisterDeviceAsync(isBot: true);

        // The only device-update endpoint is push-token; smuggling isBot into
        // its body must be ignored. Since the X0 IDOR fix a device can only
        // update its OWN token, so the bot's row is out of reach entirely (403).
        (await Client.PutAsJsonAsync($"/devices/{humanId}/push-token",
            new { token = "t1", platform = "fcm", isBot = true })).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await Client.PutAsJsonAsync($"/devices/{botId}/push-token",
            new { token = "t2", platform = "fcm", isBot = false })).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Registering again always creates a NEW device — it cannot rewrite an
        // existing one, so the originals keep their flag.
        await RegisterDeviceAsync(isBot: true);

        (await GetIsBotFromKeyBundleAsync(humanId)).Should().BeFalse();
        (await GetIsBotFromKeyBundleAsync(botId)).Should().BeTrue();
    }
}
