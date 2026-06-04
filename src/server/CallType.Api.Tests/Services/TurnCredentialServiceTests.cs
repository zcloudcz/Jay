// ---------------------------------------------------------------------------
// TurnCredentialServiceTests.cs — Unit tests for TURN credential generation
// ---------------------------------------------------------------------------
// These are pure unit tests (no DB, no Testcontainers) because
// TurnCredentialService is stateless — it reads config and computes HMACs.
// The time parameter is injected so tests are fully deterministic.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.Extensions.Configuration;
using CallType.Api.Services;

namespace CallType.Api.Tests.Services;

public class TurnCredentialServiceTests
{
    private const string SharedSecret = "test-shared-secret";
    private const int TtlSeconds = 3600;

    /// <summary>
    /// Creates a TurnCredentialService with the given shared secret and TTL.
    /// Uses in-memory configuration to avoid touching the filesystem.
    /// </summary>
    private static TurnCredentialService CreateService(
        string? secret = SharedSecret,
        int ttl = TtlSeconds)
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Turn:SharedSecret"] = secret,
                ["Turn:TtlSeconds"] = ttl.ToString()
            })
            .Build();

        return new TurnCredentialService(config);
    }

    [Fact]
    public void Generate_returns_valid_credentials()
    {
        // Arrange
        var service = CreateService();
        var deviceId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;

        // Act
        var result = service.Generate(deviceId, now);

        // Assert — credential should be non-empty base64
        result.Credential.Should().NotBeNullOrEmpty();
        result.Username.Should().NotBeNullOrEmpty();
        result.TtlSeconds.Should().Be(TtlSeconds);

        // Username format: {expiry_unix}:{deviceId}
        result.Username.Should().Contain(deviceId.ToString(),
            "username must contain the deviceId for TURN server correlation");
        result.Username.Should().Contain(":",
            "username must use colon-separated format for TURN compatibility");

        // Credential should be valid base64 (not just any string).
        var credentialAction = () => Convert.FromBase64String(result.Credential);
        credentialAction.Should().NotThrow("credential must be valid base64");

        // The expiry in the username should be in the future.
        var parts = result.Username.Split(':');
        var expiryUnix = long.Parse(parts[0]);
        var expiry = DateTimeOffset.FromUnixTimeSeconds(expiryUnix);
        expiry.Should().BeAfter(now, "expiry must be in the future");
    }

    [Fact]
    public void Same_input_same_time_produces_same_credential()
    {
        // HMAC is deterministic — same secret + same username -> same credential.
        // This test verifies the service doesn't accidentally inject randomness.
        var service = CreateService();
        var deviceId = Guid.NewGuid();
        var fixedTime = new DateTimeOffset(2026, 5, 29, 12, 0, 0, TimeSpan.Zero);

        // Act
        var result1 = service.Generate(deviceId, fixedTime);
        var result2 = service.Generate(deviceId, fixedTime);

        // Assert
        result1.Username.Should().Be(result2.Username);
        result1.Credential.Should().Be(result2.Credential,
            "HMAC-SHA1 is deterministic — identical inputs must produce identical output");
    }

    [Fact]
    public void Different_devices_produce_different_credentials()
    {
        // Different deviceIds -> different usernames -> different HMACs.
        var service = CreateService();
        var fixedTime = new DateTimeOffset(2026, 5, 29, 12, 0, 0, TimeSpan.Zero);

        var result1 = service.Generate(Guid.NewGuid(), fixedTime);
        var result2 = service.Generate(Guid.NewGuid(), fixedTime);

        result1.Credential.Should().NotBe(result2.Credential,
            "different devices must get different credentials");
    }

    [Fact]
    public void Different_secrets_produce_different_credentials()
    {
        // Changing the shared secret must change the output — verifies the secret
        // is actually used in the HMAC, not ignored.
        var service1 = CreateService(secret: "secret-one");
        var service2 = CreateService(secret: "secret-two");

        var deviceId = Guid.NewGuid();
        var fixedTime = new DateTimeOffset(2026, 5, 29, 12, 0, 0, TimeSpan.Zero);

        var result1 = service1.Generate(deviceId, fixedTime);
        var result2 = service2.Generate(deviceId, fixedTime);

        result1.Credential.Should().NotBe(result2.Credential,
            "different shared secrets must produce different credentials");
    }

    [Fact]
    public void Missing_shared_secret_throws_on_construction()
    {
        // The service should fail fast if the secret is missing — not silently
        // generate invalid credentials at runtime.
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>())
            .Build();

        var act = () => new TurnCredentialService(config);

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*SharedSecret*");
    }

    [Fact]
    public void Default_ttl_is_24_hours_when_not_configured()
    {
        // When Turn:TtlSeconds is missing, the service should default to 86400 (24h).
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Turn:SharedSecret"] = SharedSecret
                // No Turn:TtlSeconds — should default
            })
            .Build();

        var service = new TurnCredentialService(config);
        var result = service.Generate(Guid.NewGuid(), DateTimeOffset.UtcNow);

        result.TtlSeconds.Should().Be(86400);
    }
}
