// ---------------------------------------------------------------------------
// ApnsAndFcmSenderTests.cs - Provider senders against a fake HTTP layer
// ---------------------------------------------------------------------------
// Covers the parts Apple/Google would reject silently in production: APNs
// HTTP/2 + headers + ES256 provider token (shape, signature, 50 min cache),
// FCM visible message, and which provider answers mean "token is dead".
// ---------------------------------------------------------------------------

using System.Buffers.Text;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using CallType.Api.Configuration;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class ApnsAndFcmSenderTests
{
    private static readonly string DeviceToken = new('a', 64);
    private const string Conv = "3f2b7c1e-9a4d-4c55-8f10-6d2e1a7b9c01";

    private static (ApnsSender Sender, FakePushService Service, ECDsa Key, FakeTimeProvider Clock) NewApns(
        bool sandbox = false)
    {
        var (pem, key) = PushKeys.NewApnsKey();
        var service = new FakePushService();
        var clock = new FakeTimeProvider(new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero));
        var sender = new ApnsSender(new FakeHttpClientFactory(service),
            Options.Create(new ApnsOptions { KeyId = "ABC123DEFG", PrivateKeyP8 = pem, UseSandbox = sandbox }),
            clock, NullLogger<ApnsSender>.Instance);
        return (sender, service, key, clock);
    }

    [Fact]
    public async Task Apns_request_is_http2_with_alert_headers_and_golden_body()
    {
        var (sender, service, key, _) = NewApns();
        using var _k = key;

        var result = await sender.SendAsync(DeviceToken, new PushNotification(PushTypes.Message, Conv), "cs",
            CancellationToken.None);

        result.Should().Be(PushSendResult.Sent);
        var r = service.Requests.Single();
        r.Request.RequestUri.Should().Be(new Uri($"https://api.push.apple.com/3/device/{DeviceToken}"));
        r.Request.Version.Should().Be(HttpVersion.Version20);
        r.Request.VersionPolicy.Should().Be(HttpVersionPolicy.RequestVersionExact);
        r.Header("apns-push-type").Should().Be("alert");
        r.Header("apns-topic").Should().Be("cz.zcloud.jay");
        r.Header("apns-priority").Should().Be("10");
        r.Header("apns-collapse-id").Should().Be(Conv);
        r.Header("authorization").Should().StartWith("bearer ");
        r.BodyText.Should().Be(
            "{\"aps\":{\"alert\":{\"title\":\"Jay\",\"body\":\"Nová zpráva\"},\"sound\":\"default\"," +
            "\"thread-id\":\"" + Conv + "\",\"mutable-content\":1}," +
            "\"type\":\"message\",\"conversationId\":\"" + Conv + "\",\"v\":\"1\"}");
    }

    [Fact]
    public async Task Apns_sandbox_switches_the_host()
    {
        var (sender, service, key, _) = NewApns(sandbox: true);
        using var _k = key;

        await sender.SendAsync(DeviceToken, new PushNotification(PushTypes.Message, Conv), null, CancellationToken.None);

        service.Requests.Single().Request.RequestUri!.Host.Should().Be("api.sandbox.push.apple.com");
    }

    [Fact]
    public void Apns_provider_token_is_an_ES256_JWT_cached_for_50_minutes()
    {
        var (sender, _, key, clock) = NewApns();
        using var _k = key;

        var token = sender.GetProviderToken();
        var parts = token.Split('.');
        parts.Should().HaveCount(3);
        var header = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[0])).RootElement;
        header.GetProperty("alg").GetString().Should().Be("ES256");
        header.GetProperty("kid").GetString().Should().Be("ABC123DEFG");
        var claims = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[1])).RootElement;
        claims.GetProperty("iss").GetString().Should().Be("DZR3FD9ZNT");
        claims.GetProperty("iat").GetInt64().Should().Be(clock.GetUtcNow().ToUnixTimeSeconds());
        var signature = Base64Url.DecodeFromChars(parts[2]);
        signature.Should().HaveCount(64, "JWS ES256 uses the raw r||s form, not DER");
        key.VerifyData(Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]), signature, HashAlgorithmName.SHA256)
            .Should().BeTrue();

        clock.Advance(TimeSpan.FromMinutes(49));
        sender.GetProviderToken().Should().Be(token);
        clock.Advance(TimeSpan.FromMinutes(1));
        sender.GetProviderToken().Should().NotBe(token);
    }

    [Theory]
    [InlineData(HttpStatusCode.Gone, "{\"reason\":\"Unregistered\"}", PushSendResult.TokenInvalid)]
    [InlineData(HttpStatusCode.BadRequest, "{\"reason\":\"BadDeviceToken\"}", PushSendResult.TokenInvalid)]
    [InlineData(HttpStatusCode.BadRequest, "{\"reason\":\"Unregistered\"}", PushSendResult.TokenInvalid)]
    [InlineData(HttpStatusCode.BadRequest, "{\"reason\":\"BadCollapseId\"}", PushSendResult.Failed)]
    [InlineData(HttpStatusCode.TooManyRequests, "{\"reason\":\"TooManyRequests\"}", PushSendResult.Failed)]
    [InlineData(HttpStatusCode.InternalServerError, "", PushSendResult.Failed)]
    public async Task Apns_status_and_reason_map_to_the_result(HttpStatusCode status, string body,
        PushSendResult expected)
    {
        var (sender, service, key, _) = NewApns();
        using var _k = key;
        service.Respond = _ => new HttpResponseMessage(status) { Content = new StringContent(body) };

        (await sender.SendAsync(DeviceToken, new PushNotification(PushTypes.Message, Conv), null,
            CancellationToken.None)).Should().Be(expected);
    }

    [Fact]
    public async Task Apns_expired_provider_token_is_minted_again_on_the_next_push()
    {
        var (sender, service, key, _) = NewApns();
        using var _k = key;
        var first = sender.GetProviderToken();
        service.Respond = _ => new HttpResponseMessage(HttpStatusCode.Forbidden)
            { Content = new StringContent("{\"reason\":\"ExpiredProviderToken\"}") };

        (await sender.SendAsync(DeviceToken, new PushNotification(PushTypes.Message, Conv), null,
            CancellationToken.None)).Should().Be(PushSendResult.Failed);

        // Same second, so only the dropped cache can explain a new object;
        // compare by reference rather than text (iat would be identical).
        ReferenceEquals(sender.GetProviderToken(), first).Should().BeFalse();
    }

    [Fact]
    public async Task Apns_without_key_is_disabled_and_sends_nothing()
    {
        var service = new FakePushService();
        foreach (var options in new[]
                 {
                     new ApnsOptions(),
                     new ApnsOptions { KeyId = "K", PrivateKeyP8 = "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----" },
                 })
        {
            var sender = new ApnsSender(new FakeHttpClientFactory(service), Options.Create(options),
                TimeProvider.System, NullLogger<ApnsSender>.Instance);
            sender.IsConfigured.Should().BeFalse();
            (await sender.SendAsync(DeviceToken, new PushNotification(PushTypes.Message, Conv), null,
                CancellationToken.None)).Should().Be(PushSendResult.Disabled);
        }
        service.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task Fcm_sends_a_visible_collapsed_message_with_bearer_token()
    {
        var service = new FakePushService();
        var sender = new FcmSender(new FakeHttpClientFactory(service), new FakeFcmTokens(),
            NullLogger<FcmSender>.Instance);

        var result = await sender.SendAsync("fcm-token", new PushNotification(PushTypes.IncomingCall, Conv), "en",
            CancellationToken.None);

        result.Should().Be(PushSendResult.Sent);
        var r = service.Requests.Single();
        r.Request.RequestUri.Should().Be(new Uri("https://fcm.googleapis.com/v1/projects/test-project/messages:send"));
        r.Header("Authorization").Should().Be("Bearer test-access-token");
        r.BodyText.Should().Be(PushPayloads.Serialize(
            PushPayloads.Fcm("fcm-token", new PushNotification(PushTypes.IncomingCall, Conv), "en")));
        r.BodyText.Should().Contain("\"channel_id\":\"calls\"").And.Contain("\"body\":\"Incoming call\"");
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound,
        "{\"error\":{\"details\":[{\"errorCode\":\"UNREGISTERED\"}]}}", PushSendResult.TokenInvalid)]
    [InlineData(HttpStatusCode.NotFound, "{\"error\":{}}", PushSendResult.Failed)]
    [InlineData(HttpStatusCode.ServiceUnavailable, "", PushSendResult.Failed)]
    public async Task Fcm_only_unregistered_clears_the_token(HttpStatusCode status, string body,
        PushSendResult expected)
    {
        var service = new FakePushService
        {
            Respond = _ => new HttpResponseMessage(status) { Content = new StringContent(body) }
        };
        var sender = new FcmSender(new FakeHttpClientFactory(service), new FakeFcmTokens(),
            NullLogger<FcmSender>.Instance);

        (await sender.SendAsync("t", new PushNotification(PushTypes.Message, Conv), null, CancellationToken.None))
            .Should().Be(expected);
    }

    [Fact]
    public async Task Fcm_without_service_account_is_disabled()
    {
        var service = new FakePushService();
        var sender = new FcmSender(new FakeHttpClientFactory(service), new FakeFcmTokens { IsConfigured = false },
            NullLogger<FcmSender>.Instance);

        (await sender.SendAsync("t", new PushNotification(PushTypes.Message, Conv), null, CancellationToken.None))
            .Should().Be(PushSendResult.Disabled);
        service.Requests.Should().BeEmpty();
    }
}
