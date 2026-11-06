// ---------------------------------------------------------------------------
// ApnsSender.cs - iOS push straight to Apple (HTTP/2, token auth)
// ---------------------------------------------------------------------------
// Talks to APNs directly instead of through Firebase: Firebase is not set up
// yet and iOS should not need Google at all (spec decision N3). Token-based
// auth: an ES256 JWT signed with the team's .p8 key, cached for 50 minutes
// because Apple rejects tokens older than one hour AND throttles providers
// that mint a new one more often than every 20 minutes (TooManyProviderTokenUpdates).
// APNs speaks HTTP/2 only, hence the request version pinning below.
// ---------------------------------------------------------------------------

using System.Buffers.Text;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;
using CallType.Api.Configuration;

namespace CallType.Api.Services;

/// <summary>Compact JWS with ES256 (used by APNs provider tokens and VAPID).</summary>
internal static class Es256Jwt
{
    public static string Create(ECDsa key, JsonObject header, JsonObject claims)
    {
        var signingInput = Base64Url.EncodeToString(Encoding.UTF8.GetBytes(header.ToJsonString())) + "." +
                           Base64Url.EncodeToString(Encoding.UTF8.GetBytes(claims.ToJsonString()));
        // JWS wants the raw 64-byte r||s form (IEEE P1363), which is what
        // SignData produces by default; DER would be rejected by Apple and
        // every push service.
        var signature = key.SignData(Encoding.ASCII.GetBytes(signingInput), HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        return signingInput + "." + Base64Url.EncodeToString(signature);
    }
}

public sealed partial class ApnsSender : IPushSender, IDisposable
{
    public const string HttpClientName = "apns";

    /// <summary>Apple: refresh no more than every 20 min, never older than 60 min.</summary>
    internal static readonly TimeSpan TokenLifetime = TimeSpan.FromMinutes(50);

    private readonly IHttpClientFactory _httpFactory;
    private readonly ApnsOptions _options;
    private readonly TimeProvider _clock;
    private readonly ILogger<ApnsSender> _logger;
    private readonly ECDsa? _key;
    private readonly Lock _tokenLock = new();
    private string? _cachedToken;
    private DateTimeOffset _cachedAt;

    public ApnsSender(IHttpClientFactory httpFactory, IOptions<ApnsOptions> options, TimeProvider clock,
        ILogger<ApnsSender> logger)
    {
        _httpFactory = httpFactory;
        _options = options.Value;
        _clock = clock;
        _logger = logger;
        if (!_options.IsConfigured)
        {
            logger.LogInformation("APNs push disabled (Push:Apns:KeyId / Push:Apns:PrivateKeyP8 not set)");
            return;
        }
        try
        {
            var key = ECDsa.Create();
            key.ImportFromPem(_options.PrivateKeyP8);
            _key = key;
        }
        catch (Exception ex) when (ex is ArgumentException or CryptographicException)
        {
            // A broken secret must not take the API down: push is optional.
            logger.LogError(ex, "Push:Apns:PrivateKeyP8 could not be parsed, APNs push is DISABLED");
        }
    }

    public string Platform => "apns";

    public bool IsConfigured => _key is not null;

    private string Host => _options.UseSandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";

    /// <summary>The cached provider token, minted again after <see cref="TokenLifetime"/>.</summary>
    internal string GetProviderToken()
    {
        lock (_tokenLock)
        {
            var now = _clock.GetUtcNow();
            if (_cachedToken is not null && now - _cachedAt < TokenLifetime) return _cachedToken;
            _cachedToken = Es256Jwt.Create(_key!,
                new JsonObject { ["alg"] = "ES256", ["kid"] = _options.KeyId },
                new JsonObject { ["iss"] = _options.TeamId, ["iat"] = now.ToUnixTimeSeconds() });
            _cachedAt = now;
            return _cachedToken;
        }
    }

    private void DropProviderToken()
    {
        lock (_tokenLock) _cachedToken = null;
    }

    public async Task<PushSendResult> SendAsync(string token, PushNotification notification, string? locale,
        CancellationToken ct)
    {
        if (_key is null) return PushSendResult.Disabled;
        // Registration already validates the hex form; this guards the URL
        // path against anything stored before validation existed.
        if (!HexToken().IsMatch(token)) return PushSendResult.TokenInvalid;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{Host}/3/device/{token}")
            {
                // Set on the message, not only as client defaults: the client
                // defaults apply to the convenience methods, SendAsync uses
                // the message's own version.
                Version = HttpVersion.Version20,
                VersionPolicy = HttpVersionPolicy.RequestVersionExact,
                Content = new StringContent(PushPayloads.Serialize(PushPayloads.Apns(notification, locale)),
                    Encoding.UTF8, "application/json"),
            };
            request.Headers.TryAddWithoutValidation("authorization", "bearer " + GetProviderToken());
            request.Headers.TryAddWithoutValidation("apns-push-type", "alert");
            request.Headers.TryAddWithoutValidation("apns-topic", _options.BundleId);
            request.Headers.TryAddWithoutValidation("apns-priority", "10");
            request.Headers.TryAddWithoutValidation("apns-collapse-id",
                PushCollapse.ApnsCollapseId(notification.ConversationId));

            using var response = await _httpFactory.CreateClient(HttpClientName).SendAsync(request, ct);
            if (response.IsSuccessStatusCode) return PushSendResult.Sent;

            var reason = await ReadReasonAsync(response, ct);
            // 410 = the app was uninstalled / token expired. 400 BadDeviceToken
            // = not a token for this environment or garbage. Both are permanent.
            if (response.StatusCode == HttpStatusCode.Gone || reason is "BadDeviceToken" or "Unregistered")
                return PushSendResult.TokenInvalid;
            if (reason is "ExpiredProviderToken" or "InvalidProviderToken")
                DropProviderToken();
            // Apple's reason is a fixed enum string, safe to log (no token, no payload).
            _logger.LogWarning("APNs push failed with status {StatusCode} ({Reason})",
                (int)response.StatusCode, reason);
            return PushSendResult.Failed;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "APNs push failed with exception");
            return PushSendResult.Failed;
        }
    }

    private static async Task<string?> ReadReasonAsync(HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
            return doc.RootElement.TryGetProperty("reason", out var r) ? r.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    [GeneratedRegex("^[0-9a-f]{64,200}$")]
    internal static partial Regex HexToken();

    public void Dispose() => _key?.Dispose();
}
