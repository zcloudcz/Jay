// ---------------------------------------------------------------------------
// PushFakes.cs - Fake HTTP layer and key material for push provider tests
// ---------------------------------------------------------------------------
// The push senders reach Apple/Google/browser push services through named
// HttpClients. Tests replace only the primary HttpMessageHandler, so the real
// request building, headers, encryption and response mapping all run; only
// the network is fake. Keys are generated per test run, never checked in.
// ---------------------------------------------------------------------------

using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using CallType.Api.Services;

namespace CallType.Api.Tests.TestFixtures;

/// <summary>A request as the fake push service saw it (body read eagerly).</summary>
public sealed record RecordedRequest(HttpRequestMessage Request, byte[] Body)
{
    public string BodyText => Encoding.UTF8.GetString(Body);

    public string? Header(string name) =>
        Request.Headers.TryGetValues(name, out var values) ? string.Join(",", values)
        : Request.Content?.Headers.TryGetValues(name, out var cv) == true ? string.Join(",", cv) : null;
}

/// <summary>Shared recorder; a fresh handler is created per HttpClient but all report here.</summary>
public sealed class FakePushService
{
    public ConcurrentQueue<RecordedRequest> Requests { get; } = new();

    public Func<RecordedRequest, HttpResponseMessage> Respond { get; set; } =
        _ => new HttpResponseMessage(HttpStatusCode.OK);

    public HttpMessageHandler CreateHandler() => new Handler(this);

    private sealed class Handler(FakePushService owner) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(cancellationToken);
            var recorded = new RecordedRequest(request, body);
            owner.Requests.Enqueue(recorded);
            return owner.Respond(recorded);
        }
    }
}

public sealed class FakeHttpClientFactory(FakePushService service) : IHttpClientFactory
{
    public HttpClient CreateClient(string name) => new(service.CreateHandler());
}

/// <summary>FCM access tokens without a Google service account.</summary>
public sealed class FakeFcmTokens : IFcmAccessTokenSource
{
    public bool IsConfigured { get; init; } = true;
    public string? ProjectId => "test-project";
    public Task<string> GetAccessTokenAsync(CancellationToken ct = default) => Task.FromResult("test-access-token");
}

public static class PushKeys
{
    /// <summary>A fresh APNs-style .p8 (PKCS#8 PEM, P-256).</summary>
    public static (string Pem, ECDsa Key) NewApnsKey()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        return (key.ExportPkcs8PrivateKeyPem(), key);
    }

    /// <summary>A fresh VAPID pair in the configured base64url form.</summary>
    public static (string PublicKey, string PrivateKey) NewVapidKeys()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(true);
        return (Base64Url.EncodeToString([0x04, .. p.Q.X!, .. p.Q.Y!]), Base64Url.EncodeToString(p.D!));
    }

    /// <summary>A browser-side subscription: its JSON token and the private key to decrypt pushes.</summary>
    public static (string Json, ECDiffieHellman Key, byte[] Auth) NewSubscription(
        string endpoint = "https://push.example.net/push/abc")
    {
        var key = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(false);
        var auth = RandomNumberGenerator.GetBytes(16);
        var p256dh = Base64Url.EncodeToString([0x04, .. p.Q.X!, .. p.Q.Y!]);
        var json = "{\"endpoint\":\"" + endpoint + "\",\"expirationTime\":null,\"keys\":{\"p256dh\":\"" + p256dh +
                   "\",\"auth\":\"" + Base64Url.EncodeToString(auth) + "\"}}";
        return (json, key, auth);
    }

    /// <summary>
    /// Receiver side of RFC 8291 (what a browser does), written independently
    /// of the sender code so a round trip proves interoperability.
    /// </summary>
    public static byte[] Decrypt(byte[] body, ECDiffieHellman uaKey, byte[] auth)
    {
        var salt = body[..16];
        var idLen = body[20];
        var asPublic = body[21..(21 + idLen)];
        var cipher = body[(21 + idLen)..^16];
        var tag = body[^16..];
        var uaParams = uaKey.ExportParameters(false);
        byte[] uaPublic = [0x04, .. uaParams.Q.X!, .. uaParams.Q.Y!];
        using var asKey = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = asPublic[1..33], Y = asPublic[33..65] },
        });
        var secret = uaKey.DeriveRawSecretAgreement(asKey.PublicKey);
        var prkKey = HMACSHA256.HashData(auth, secret);
        byte[] keyInfo = [.. "WebPush: info\0"u8, .. uaPublic, .. asPublic, 0x01];
        byte[] cekInfo = [.. "Content-Encoding: aes128gcm\0"u8, 0x01];
        byte[] nonceInfo = [.. "Content-Encoding: nonce\0"u8, 0x01];
        var ikm = HMACSHA256.HashData(prkKey, keyInfo);
        var prk = HMACSHA256.HashData(salt, ikm);
        var cek = HMACSHA256.HashData(prk, cekInfo)[..16];
        var nonce = HMACSHA256.HashData(prk, nonceInfo)[..12];
        var plain = new byte[cipher.Length];
        using (var aes = new AesGcm(cek, 16)) aes.Decrypt(nonce, cipher, tag, plain);
        // Strip padding: trailing zeros, then the 0x02 last-record delimiter.
        var end = plain.Length - 1;
        while (plain[end] == 0) end--;
        if (plain[end] != 0x02) throw new CryptographicException("missing last-record delimiter");
        return plain[..end];
    }
}
