// ---------------------------------------------------------------------------
// WebPush.cs - Browser push (RFC 8030 + VAPID RFC 8292 + RFC 8291 encryption)
// ---------------------------------------------------------------------------
// Own implementation on System.Security.Cryptography instead of a NuGet:
// the only maintained candidate (Lib.Net.Http.WebPush, MIT) has had no release
// since early 2025, while the whole protocol here is one ECDH, two HKDFs and
// one AES-GCM record (~100 lines). Same reasoning as FcmTokenProvider avoiding
// the Firebase SDK. Correctness is pinned by the RFC 8291 section 5 example
// vector in WebPushEncryptionTests, which this code reproduces byte for byte.
// ---------------------------------------------------------------------------

using System.Buffers.Binary;
using System.Buffers.Text;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Options;
using CallType.Api.Configuration;

namespace CallType.Api.Services;

/// <summary>
/// A browser PushSubscription as stored in Device.PushToken: the JSON of
/// <c>PushSubscription.toJSON()</c> reduced to endpoint + keys.
/// </summary>
public sealed record WebPushSubscription(string Endpoint, byte[] P256dh, byte[] Auth)
{
    /// <summary>
    /// Parses and validates; null when anything is off. Strict on purpose: a
    /// subscription that cannot be encrypted for would only fail later, at
    /// push time, where nobody sees the error.
    /// </summary>
    public static WebPushSubscription? TryParse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("endpoint", out var endpointEl) || endpointEl.ValueKind != JsonValueKind.String
                || !root.TryGetProperty("keys", out var keys) || keys.ValueKind != JsonValueKind.Object
                || !keys.TryGetProperty("p256dh", out var p256dhEl) || p256dhEl.ValueKind != JsonValueKind.String
                || !keys.TryGetProperty("auth", out var authEl) || authEl.ValueKind != JsonValueKind.String)
                return null;
            var endpoint = endpointEl.GetString()!;
            // https only: the push service is a third party on the internet,
            // and an http:// or internal URL would turn the server into a
            // request forwarder (SSRF).
            if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
                return null;
            // Real push services are public DNS names; an IP literal or
            // localhost can only aim the server at its own network.
            if (uri.IsLoopback || uri.HostNameType is UriHostNameType.IPv4 or UriHostNameType.IPv6)
                return null;
            var p256dh = DecodeBase64Url(p256dhEl.GetString()!);
            var auth = DecodeBase64Url(authEl.GetString()!);
            // Uncompressed P-256 point (0x04 || X || Y) and the 16-byte auth secret (RFC 8291 section 3).
            if (p256dh is not { Length: 65 } || p256dh[0] != 0x04 || auth is not { Length: 16 }) return null;
            return new WebPushSubscription(endpoint, p256dh, auth);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// Canonical stored form: drops browser extras (expirationTime) so the
    /// same subscription always compares equal when a token is cleared.
    /// </summary>
    public string ToJson() => new JsonObject
    {
        ["endpoint"] = Endpoint,
        ["keys"] = new JsonObject
        {
            ["p256dh"] = Base64Url.EncodeToString(P256dh),
            ["auth"] = Base64Url.EncodeToString(Auth),
        },
    }.ToJsonString();

    internal static byte[]? DecodeBase64Url(string value)
    {
        // Browsers send unpadded base64url; tolerate padding and plain
        // base64 from hand-written clients too.
        var s = value.TrimEnd('=').Replace('+', '-').Replace('/', '_');
        try { return Base64Url.DecodeFromChars(s); }
        catch (FormatException) { return null; }
    }
}

/// <summary>RFC 8291 message encryption (aes128gcm content coding, one record).</summary>
public static class WebPushEncryption
{
    /// <summary>Record size advertised in the header; our payloads are far below it.</summary>
    private const int RecordSize = 4096;

    /// <summary>
    /// Encrypts <paramref name="plaintext"/> for one subscription. The sender
    /// key pair and salt are random per message (they must never repeat);
    /// the optional parameters exist only so tests can replay the RFC vector.
    /// </summary>
    public static byte[] Encrypt(byte[] plaintext, byte[] uaPublic, byte[] authSecret,
        ECDiffieHellman? senderKey = null, byte[]? salt = null)
    {
        // 16 tag + 1 delimiter + header must fit one record; a multi-record
        // payload is never needed for a generic notification.
        if (plaintext.Length > RecordSize - 17)
            throw new ArgumentException("Web Push payload too large for one record.", nameof(plaintext));

        using var ownKey = senderKey is null ? ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256) : null;
        var asKey = senderKey ?? ownKey!;
        salt ??= RandomNumberGenerator.GetBytes(16);

        var asParams = asKey.ExportParameters(false);
        var asPublic = UncompressedPoint(asParams.Q);
        using var ua = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = uaPublic[1..33], Y = uaPublic[33..65] },
        });
        var ecdhSecret = asKey.DeriveRawSecretAgreement(ua.PublicKey);

        // RFC 8291 section 3.4: IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info" || 0x00 || ua_public || as_public, 32)
        var keyInfo = Concat(Encoding.ASCII.GetBytes("WebPush: info\0"), uaPublic, asPublic);
        var ikm = HKDF.DeriveKey(HashAlgorithmName.SHA256, ecdhSecret, 32, authSecret, keyInfo);
        // RFC 8188: CEK and NONCE from HKDF(salt, IKM, ...)
        var prk = HKDF.Extract(HashAlgorithmName.SHA256, ikm, salt);
        var cek = HKDF.Expand(HashAlgorithmName.SHA256, prk, 16,
            Encoding.ASCII.GetBytes("Content-Encoding: aes128gcm\0"));
        var nonce = HKDF.Expand(HashAlgorithmName.SHA256, prk, 12,
            Encoding.ASCII.GetBytes("Content-Encoding: nonce\0"));

        // Last (and only) record: plaintext || 0x02, no extra padding.
        var padded = new byte[plaintext.Length + 1];
        plaintext.CopyTo(padded, 0);
        padded[^1] = 0x02;
        var cipher = new byte[padded.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(cek, 16))
            aes.Encrypt(nonce, padded, cipher, tag);

        // Header: salt(16) || rs(4, big endian) || idlen(1) || keyid(as_public)
        var header = new byte[16 + 4 + 1 + asPublic.Length];
        salt.CopyTo(header, 0);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(16), RecordSize);
        header[20] = (byte)asPublic.Length;
        asPublic.CopyTo(header, 21);
        return Concat(header, cipher, tag);
    }

    internal static byte[] UncompressedPoint(ECPoint q) => Concat([0x04], q.X!, q.Y!);

    private static byte[] Concat(params byte[][] parts)
    {
        var result = new byte[parts.Sum(p => p.Length)];
        var offset = 0;
        foreach (var p in parts)
        {
            p.CopyTo(result, offset);
            offset += p.Length;
        }
        return result;
    }
}

public sealed class WebPushSender : IPushSender, IDisposable
{
    public const string HttpClientName = "webpush";

    /// <summary>
    /// VAPID tokens may live at most 24 h (RFC 8292 section 2); 12 h leaves
    /// room for clock skew between us and the push service.
    /// </summary>
    internal static readonly TimeSpan VapidLifetime = TimeSpan.FromHours(12);

    private readonly IHttpClientFactory _httpFactory;
    private readonly WebPushOptions _options;
    private readonly TimeProvider _clock;
    private readonly ILogger<WebPushSender> _logger;
    private readonly ECDsa? _vapidKey;

    public WebPushSender(IHttpClientFactory httpFactory, IOptions<WebPushOptions> options, TimeProvider clock,
        ILogger<WebPushSender> logger)
    {
        _httpFactory = httpFactory;
        _options = options.Value;
        _clock = clock;
        _logger = logger;
        if (!_options.IsConfigured)
        {
            logger.LogInformation("Web Push disabled (Push:WebPush:PublicKey / Push:WebPush:PrivateKey not set)");
            return;
        }
        try
        {
            var pub = WebPushSubscription.DecodeBase64Url(_options.PublicKey!);
            var priv = WebPushSubscription.DecodeBase64Url(_options.PrivateKey!);
            if (pub is not { Length: 65 } || pub[0] != 0x04 || priv is not { Length: 32 })
                throw new CryptographicException("VAPID keys must be a 65-byte public point and a 32-byte scalar.");
            var key = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                D = priv,
                Q = new ECPoint { X = pub[1..33], Y = pub[33..65] },
            });
            // Importing D and Q does not prove they belong together; a
            // mismatched pair would make every push service answer 403 while
            // the browser happily subscribes with the public key.
            using var check = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = pub[1..33], Y = pub[33..65] },
            });
            var probe = key.SignData("vapid"u8.ToArray(), HashAlgorithmName.SHA256);
            if (!check.VerifyData("vapid"u8.ToArray(), probe, HashAlgorithmName.SHA256))
                throw new CryptographicException("VAPID public key does not match the private key.");
            _vapidKey = key;
            PublicKey = Base64Url.EncodeToString(pub);
        }
        catch (Exception ex) when (ex is ArgumentException or CryptographicException)
        {
            logger.LogError(ex, "Push:WebPush keys could not be loaded, Web Push is DISABLED");
        }
    }

    public string Platform => "webpush";

    public bool IsConfigured => _vapidKey is not null;

    /// <summary>VAPID public key (base64url) for GET /push/webpush-key; null when disabled.</summary>
    public string? PublicKey { get; }

    /// <summary>VAPID JWT for one push service origin (RFC 8292 section 2).</summary>
    internal string CreateVapidToken(string audience) => Es256Jwt.Create(_vapidKey!,
        new JsonObject { ["typ"] = "JWT", ["alg"] = "ES256" },
        new JsonObject
        {
            ["aud"] = audience,
            ["exp"] = (_clock.GetUtcNow() + VapidLifetime).ToUnixTimeSeconds(),
            ["sub"] = _options.Subject,
        });

    public async Task<PushSendResult> SendAsync(string token, PushNotification notification, string? locale,
        CancellationToken ct)
    {
        if (_vapidKey is null) return PushSendResult.Disabled;
        var subscription = WebPushSubscription.TryParse(token);
        // Only reachable for rows written before validation existed: such a
        // token can never work, so clearing it is the right outcome.
        if (subscription is null) return PushSendResult.TokenInvalid;
        try
        {
            var plaintext = Encoding.UTF8.GetBytes(PushPayloads.Serialize(PushPayloads.WebPush(notification, locale)));
            var body = WebPushEncryption.Encrypt(plaintext, subscription.P256dh, subscription.Auth);
            var audience = new Uri(subscription.Endpoint).GetLeftPart(UriPartial.Authority);

            using var request = new HttpRequestMessage(HttpMethod.Post, subscription.Endpoint)
            {
                Content = new ByteArrayContent(body),
            };
            request.Content.Headers.ContentType = new("application/octet-stream");
            request.Content.Headers.ContentEncoding.Add("aes128gcm");
            // A day: after that a "new message" is stale, the app syncs anyway.
            request.Headers.TryAddWithoutValidation("TTL", "86400");
            request.Headers.TryAddWithoutValidation("Urgency", "high");
            // Topic replaces an undelivered push of the same chat at the push
            // service (collapse while the browser is offline).
            request.Headers.TryAddWithoutValidation("Topic", PushCollapse.WebPushTopic(notification.ConversationId));
            request.Headers.TryAddWithoutValidation("Authorization",
                $"vapid t={CreateVapidToken(audience)}, k={PublicKey}");

            using var response = await _httpFactory.CreateClient(HttpClientName).SendAsync(request, ct);
            if (response.IsSuccessStatusCode) return PushSendResult.Sent;
            // RFC 8030 section 7.3: 404/410 = the subscription expired or was revoked.
            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone)
                return PushSendResult.TokenInvalid;
            _logger.LogWarning("Web Push failed with status {StatusCode}", (int)response.StatusCode);
            return PushSendResult.Failed;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "Web Push failed with exception");
            return PushSendResult.Failed;
        }
    }

    public void Dispose() => _vapidKey?.Dispose();
}
