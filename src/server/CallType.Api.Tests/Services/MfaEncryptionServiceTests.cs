// ---------------------------------------------------------------------------
// MfaEncryptionServiceTests.cs — AES-256-GCM at-rest encryption (N03a)
// ---------------------------------------------------------------------------

using CallType.Api.Services;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace CallType.Api.Tests.Services;

public class MfaEncryptionServiceTests
{
    private static MfaEncryptionService BuildWithKey(string? base64Key)
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(base64Key is null
                ? []
                : new Dictionary<string, string?> { ["Mfa:EncryptionKey"] = base64Key })
            .Build();
        return new MfaEncryptionService(config);
    }

    [Fact]
    public void IsConfigured_FalseWhenKeyMissing()
    {
        BuildWithKey(null).IsConfigured.Should().BeFalse();
    }

    [Fact]
    public void IsConfigured_FalseWhenKeyWrongLength()
    {
        BuildWithKey(Convert.ToBase64String(new byte[16])).IsConfigured.Should().BeFalse();
    }

    [Fact]
    public void IsConfigured_FalseWhenKeyNotBase64()
    {
        BuildWithKey("not-base64!!!").IsConfigured.Should().BeFalse();
    }

    [Fact]
    public void EncryptThenDecrypt_RoundTrips()
    {
        var service = BuildWithKey(Convert.ToBase64String(new byte[32]));
        var plaintext = "top-secret-totp-seed"u8.ToArray();

        var blob = service.Encrypt(plaintext);
        blob.Should().NotEqual(plaintext); // ciphertext must not equal plaintext

        service.Decrypt(blob).Should().Equal(plaintext);
    }

    [Fact]
    public void Encrypt_UsesAFreshNoncePerCall()
    {
        var service = BuildWithKey(Convert.ToBase64String(new byte[32]));
        var plaintext = "same-plaintext"u8.ToArray();

        var blob1 = service.Encrypt(plaintext);
        var blob2 = service.Encrypt(plaintext);

        blob1.Should().NotEqual(blob2); // different nonce -> different ciphertext for identical input
    }

    [Fact]
    public void Decrypt_ThrowsWhenKeyNotConfigured()
    {
        var service = BuildWithKey(null);
        var act = () => service.Decrypt(new byte[40]);
        act.Should().Throw<InvalidOperationException>();
    }
}
