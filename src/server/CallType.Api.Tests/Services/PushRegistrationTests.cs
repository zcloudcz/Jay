// ---------------------------------------------------------------------------
// PushRegistrationTests.cs - Token/locale validation rules per platform
// ---------------------------------------------------------------------------
// Pure unit tests of PushRegistration (contract 1.1). The HTTP side (403,
// 400 codes, DELETE) is covered in PushRegistrationEndpointsTests.
// ---------------------------------------------------------------------------

using System.Text.Json;
using FluentAssertions;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class PushRegistrationTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("gcm")]
    [InlineData("FCM")]
    [InlineData("")]
    public void Unknown_platform_is_rejected(string? platform) =>
        PushRegistration.ValidateToken(platform, "token").Error.Should().Be("invalid_platform");

    [Fact]
    public void Fcm_token_is_opaque_but_bounded()
    {
        PushRegistration.ValidateToken("fcm", "abc:DEF-123").Should().Be(("abc:DEF-123", (string?)null));
        PushRegistration.ValidateToken("fcm", " ").Error.Should().Be("invalid_token");
        PushRegistration.ValidateToken("fcm", new string('a', 2049)).Error.Should().Be("invalid_token");
        PushRegistration.ValidateToken("fcm", new string('a', 2048)).Error.Should().BeNull();
    }

    [Fact]
    public void Apns_token_must_be_64_to_200_hex_chars_and_is_stored_lowercase()
    {
        var hex = new string('A', 64);
        PushRegistration.ValidateToken("apns", hex).Should().Be((new string('a', 64), (string?)null));
        PushRegistration.ValidateToken("apns", new string('f', 200)).Error.Should().BeNull();
        PushRegistration.ValidateToken("apns", new string('f', 63)).Error.Should().Be("invalid_token");
        PushRegistration.ValidateToken("apns", new string('f', 201)).Error.Should().Be("invalid_token");
        PushRegistration.ValidateToken("apns", new string('g', 64)).Error.Should().Be("invalid_token");
    }

    [Fact]
    public void WebPush_subscription_is_validated_and_stored_canonically()
    {
        var (json, key, _) = PushKeys.NewSubscription();
        using var _k = key;

        var (token, error) = PushRegistration.ValidateToken("webpush", json);

        error.Should().BeNull();
        using var doc = JsonDocument.Parse(token!);
        // expirationTime (and any other browser extra) is dropped.
        doc.RootElement.EnumerateObject().Select(p => p.Name).Should().Equal("endpoint", "keys");
        doc.RootElement.GetProperty("endpoint").GetString().Should().Be("https://push.example.net/push/abc");
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{\"endpoint\":\"https://push.example.net/x\"}")]
    [InlineData("{\"endpoint\":\"https://push.example.net/x\",\"keys\":{\"p256dh\":\"AAAA\",\"auth\":\"AAAAAAAAAAAAAAAAAAAAAA\"}}")]
    [InlineData("[1,2]")]
    public void Malformed_webpush_subscription_is_rejected(string json) =>
        PushRegistration.ValidateToken("webpush", json).Error.Should().Be("invalid_token");

    [Theory]
    [InlineData("http://push.example.net/x")]
    [InlineData("https://127.0.0.1/x")]
    [InlineData("https://localhost/x")]
    [InlineData("https://[::1]/x")]
    [InlineData("ftp://push.example.net/x")]
    public void WebPush_endpoint_must_be_a_public_https_url(string endpoint)
    {
        var (json, key, _) = PushKeys.NewSubscription(endpoint);
        using var _k = key;
        PushRegistration.ValidateToken("webpush", json).Error.Should().Be("invalid_token");
    }

    [Theory]
    [InlineData(null, null)]
    [InlineData("", null)]
    [InlineData("cs", "cs")]
    [InlineData("en-US", "en-US")]
    [InlineData("zh-Hant-TW", "zh-Hant-TW")]
    [InlineData("cs_CZ", "cs_CZ")]
    public void Valid_locales_are_kept(string? input, string? stored) =>
        PushRegistration.ValidateLocale(input).Should().Be((stored, (string?)null));

    [Theory]
    [InlineData("c")]
    [InlineData("en US")]
    [InlineData("en-US-x-private-too-long")]
    [InlineData("<script>")]
    public void Invalid_locales_are_rejected(string input) =>
        PushRegistration.ValidateLocale(input).Error.Should().Be("invalid_locale");
}
