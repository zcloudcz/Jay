// ---------------------------------------------------------------------------
// WebPushTests.cs - RFC 8291 encryption, VAPID and the Web Push sender
// ---------------------------------------------------------------------------
// The encryption is our own code (no NuGet), so it is pinned to the RFC 8291
// section 5 example byte for byte, and additionally round-tripped through an
// independent receiver implementation (PushKeys.Decrypt) with random keys.
// The sender runs against a fake push service (no network).
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

public class WebPushTests
{
    // RFC 8291 section 5.
    private const string Plaintext = "When I grow up, I want to be a watermelon";
    private const string AuthSecret = "BTBZMqHH6r4Tts7J_aSIgg";
    private const string ReceiverPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94";
    private const string ReceiverPublic =
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
    private const string SenderPrivate = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw";
    private const string SenderPublic =
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8";
    private const string Salt = "DGv6ra1nlYgDCS1FRnbzlw";
    private const string ExpectedBody =
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
        "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

    private static ECDiffieHellman Import(string privateKey, string publicKey)
    {
        var pub = Base64Url.DecodeFromChars(publicKey);
        return ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            D = Base64Url.DecodeFromChars(privateKey),
            Q = new ECPoint { X = pub[1..33], Y = pub[33..65] },
        });
    }

    [Fact]
    public void Encryption_reproduces_the_RFC_8291_example()
    {
        using var sender = Import(SenderPrivate, SenderPublic);

        var body = WebPushEncryption.Encrypt(Encoding.ASCII.GetBytes(Plaintext),
            Base64Url.DecodeFromChars(ReceiverPublic), Base64Url.DecodeFromChars(AuthSecret),
            sender, Base64Url.DecodeFromChars(Salt));

        Base64Url.EncodeToString(body).Should().Be(ExpectedBody);
    }

    [Fact]
    public void The_RFC_example_decrypts_with_the_independent_receiver()
    {
        using var receiver = Import(ReceiverPrivate, ReceiverPublic);

        var plain = PushKeys.Decrypt(Base64Url.DecodeFromChars(ExpectedBody), receiver,
            Base64Url.DecodeFromChars(AuthSecret));

        Encoding.ASCII.GetString(plain).Should().Be(Plaintext);
    }

    [Fact]
    public void Random_keys_round_trip_and_salt_and_key_never_repeat()
    {
        var (json, key, auth) = PushKeys.NewSubscription();
        using var _ = key;
        var sub = WebPushSubscription.TryParse(json)!;
        var message = "{\"title\":\"Jay\",\"body\":\"Nová zpráva\"}"u8.ToArray();

        var a = WebPushEncryption.Encrypt(message, sub.P256dh, sub.Auth);
        var b = WebPushEncryption.Encrypt(message, sub.P256dh, sub.Auth);

        PushKeys.Decrypt(a, key, auth).Should().Equal(message);
        PushKeys.Decrypt(b, key, auth).Should().Equal(message);
        // Fresh salt and ephemeral key per message (RFC 8291 section 2).
        a[..16].Should().NotEqual(b[..16]);
        a[21..86].Should().NotEqual(b[21..86]);
    }

    private static (WebPushSender Sender, FakePushService Service) NewSender(
        string? publicKey, string? privateKey, TimeProvider? clock = null)
    {
        var service = new FakePushService();
        var sender = new WebPushSender(new FakeHttpClientFactory(service),
            Options.Create(new WebPushOptions { PublicKey = publicKey, PrivateKey = privateKey }),
            clock ?? TimeProvider.System, NullLogger<WebPushSender>.Instance);
        return (sender, service);
    }

    [Fact]
    public async Task Sender_posts_an_encrypted_collapsible_push_with_vapid_auth()
    {
        var (pub, priv) = PushKeys.NewVapidKeys();
        var clock = new FakeTimeProvider(new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero));
        var (sender, service) = NewSender(pub, priv, clock);
        var (json, key, auth) = PushKeys.NewSubscription("https://fcm.googleapis.com/fcm/send/xyz");
        using var _ = key;
        var conv = Guid.NewGuid().ToString();

        var result = await sender.SendAsync(json, new PushNotification(PushTypes.GroupMessage, conv), "cs",
            CancellationToken.None);

        result.Should().Be(PushSendResult.Sent);
        var r = service.Requests.Single();
        r.Request.RequestUri.Should().Be(new Uri("https://fcm.googleapis.com/fcm/send/xyz"));
        r.Header("TTL").Should().Be("86400");
        r.Header("Urgency").Should().Be("high");
        r.Header("Topic").Should().Be(PushCollapse.WebPushTopic(conv));
        r.Header("Content-Encoding").Should().Be("aes128gcm");

        var plain = JsonDocument.Parse(PushKeys.Decrypt(r.Body, key, auth)).RootElement;
        plain.GetProperty("body").GetString().Should().Be("Nová zpráva ve skupině");
        plain.GetProperty("type").GetString().Should().Be("group_message");
        plain.GetProperty("conversationId").GetString().Should().Be(conv);
        plain.GetProperty("tag").GetString().Should().Be(conv);

        // Authorization: vapid t=<JWT>, k=<public key> (RFC 8292 section 3).
        var authz = r.Header("Authorization")!;
        authz.Should().StartWith("vapid t=").And.EndWith(", k=" + pub);
        var jwt = authz["vapid t=".Length..authz.IndexOf(',')];
        var parts = jwt.Split('.');
        var header = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[0])).RootElement;
        header.GetProperty("alg").GetString().Should().Be("ES256");
        var claims = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[1])).RootElement;
        claims.GetProperty("aud").GetString().Should().Be("https://fcm.googleapis.com");
        claims.GetProperty("sub").GetString().Should().Be("mailto:martin@zcloud.cz");
        claims.GetProperty("exp").GetInt64().Should().Be(clock.GetUtcNow().AddHours(12).ToUnixTimeSeconds());
        var pubBytes = Base64Url.DecodeFromChars(pub);
        using var verifier = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = pubBytes[1..33], Y = pubBytes[33..65] },
        });
        verifier.VerifyData(Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]), Base64Url.DecodeFromChars(parts[2]),
            HashAlgorithmName.SHA256).Should().BeTrue();
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound, PushSendResult.TokenInvalid)]
    [InlineData(HttpStatusCode.Gone, PushSendResult.TokenInvalid)]
    [InlineData(HttpStatusCode.Created, PushSendResult.Sent)]
    [InlineData(HttpStatusCode.TooManyRequests, PushSendResult.Failed)]
    [InlineData(HttpStatusCode.Forbidden, PushSendResult.Failed)]
    public async Task Push_service_status_maps_to_the_result(HttpStatusCode status, PushSendResult expected)
    {
        var (pub, priv) = PushKeys.NewVapidKeys();
        var (sender, service) = NewSender(pub, priv);
        service.Respond = _ => new HttpResponseMessage(status);
        var (json, key, _) = PushKeys.NewSubscription();
        using var _k = key;

        (await sender.SendAsync(json, new PushNotification(PushTypes.Message, "c"), null, CancellationToken.None))
            .Should().Be(expected);
    }

    [Fact]
    public async Task Unconfigured_or_mismatched_keys_disable_web_push()
    {
        var (pub, _) = PushKeys.NewVapidKeys();
        var (_, otherPriv) = PushKeys.NewVapidKeys();

        foreach (var (p, k) in new[] { (null, null), ("", ""), (pub, otherPriv), (pub, "not-base64!!") })
        {
            var (sender, service) = NewSender(p, k);
            sender.IsConfigured.Should().BeFalse();
            sender.PublicKey.Should().BeNull();
            (await sender.SendAsync("{}", new PushNotification(PushTypes.Message, "c"), null, CancellationToken.None))
                .Should().Be(PushSendResult.Disabled);
            service.Requests.Should().BeEmpty();
        }
    }
}
