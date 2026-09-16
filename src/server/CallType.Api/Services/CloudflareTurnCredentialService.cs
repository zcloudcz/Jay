// ---------------------------------------------------------------------------
// CloudflareTurnCredentialService.cs — TURN credentials from Cloudflare Calls
// ---------------------------------------------------------------------------
// Cloudflare hosts the TURN relay (UDP/TCP 3478, TLS 5349) so we run no coturn
// at all. Credentials are minted per request by Cloudflare's API:
//
//   POST https://rtc.live.cloudflare.com/v1/turn/keys/{keyId}/credentials/generate
//   Authorization: Bearer {apiToken}
//   { "ttl": 86400 }
//   -> { "iceServers": { "urls": [...], "username": "...", "credential": "..." } }
//
// The API token is a server-side secret and never reaches the client; the
// client only receives the short-lived username/credential pair, exactly like
// with the self-hosted HMAC scheme. Registered as a singleton (stateless,
// pooled HttpClient via IHttpClientFactory).
// ---------------------------------------------------------------------------

using System.Net.Http.Headers;
using System.Text.Json.Serialization;

namespace CallType.Api.Services;

public class CloudflareTurnCredentialService : ITurnCredentialProvider
{
    /// <summary>Named HttpClient so tests can plug in a fake handler.</summary>
    public const string HttpClientName = "cloudflare-turn";

    private readonly IHttpClientFactory _httpFactory;
    private readonly ILogger<CloudflareTurnCredentialService> _logger;
    private readonly string _apiToken;
    private readonly int _ttlSeconds;
    private readonly string[] _stunUrls;
    private readonly Uri _endpoint;

    public CloudflareTurnCredentialService(
        IHttpClientFactory httpFactory,
        IConfiguration configuration,
        ILogger<CloudflareTurnCredentialService> logger)
    {
        _httpFactory = httpFactory;
        _logger = logger;

        // Fail fast: without these the provider can never work, and a missing
        // TURN provider would only surface later as failed calls behind NAT.
        var keyId = configuration["Turn:Cloudflare:KeyId"]
            ?? throw new InvalidOperationException("Turn:Cloudflare:KeyId is not configured.");
        _apiToken = configuration["Turn:Cloudflare:ApiToken"]
            ?? throw new InvalidOperationException("Turn:Cloudflare:ApiToken is not configured.");

        _ttlSeconds = int.TryParse(configuration["Turn:TtlSeconds"], out var ttl) ? ttl : 86400;

        // Cloudflare's iceServers already contain stun: URLs; extra STUN servers
        // are optional and mainly useful while migrating away from coturn.
        _stunUrls = configuration.GetSection("Turn:StunUrls").Get<string[]>() ?? [];

        // Overridable base URL so tests (and a future regional endpoint) need no code change.
        var baseUrl = configuration["Turn:Cloudflare:BaseUrl"] ?? "https://rtc.live.cloudflare.com";
        _endpoint = new Uri($"{baseUrl.TrimEnd('/')}/v1/turn/keys/{keyId}/credentials/generate");
    }

    /// <inheritdoc />
    public async Task<TurnIceCredentials> IssueAsync(Guid deviceId, CancellationToken cancellationToken)
    {
        var client = _httpFactory.CreateClient(HttpClientName);
        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiToken);
        request.Content = JsonContent.Create(new { ttl = _ttlSeconds });

        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, cancellationToken);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            // Log only the exception type: the message could include the URL
            // with the key id. Calls still work peer-to-peer without TURN.
            _logger.LogWarning("Cloudflare TURN credential request failed: {ExceptionType}", ex.GetType().Name);
            throw new TurnUnavailableException("TURN credential provider unreachable.");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                // Never log the body — Cloudflare error payloads can echo request details.
                _logger.LogWarning("Cloudflare TURN credential request returned {StatusCode}", (int)response.StatusCode);
                throw new TurnUnavailableException("TURN credential provider rejected the request.");
            }

            GenerateResponse? payload;
            try
            {
                payload = await response.Content.ReadFromJsonAsync<GenerateResponse>(cancellationToken: cancellationToken);
            }
            catch (System.Text.Json.JsonException)
            {
                throw new TurnUnavailableException("TURN credential provider returned an unexpected response.");
            }

            var ice = payload?.IceServers;
            if (ice is null || string.IsNullOrEmpty(ice.Username) || string.IsNullOrEmpty(ice.Credential))
                throw new TurnUnavailableException("TURN credential provider returned an unexpected response.");

            // Cloudflare usernames are opaque (no device id embedded, unlike the
            // HMAC scheme), so keep the correlation in a Debug log only.
            _logger.LogDebug("Issued Cloudflare TURN credentials for device {DeviceId}", deviceId);

            return new TurnIceCredentials(ice.Username, ice.Credential, _ttlSeconds, ice.Urls ?? [], _stunUrls);
        }
    }

    // Cloudflare's documented response for /credentials/generate: `iceServers`
    // is a single object (it is an array only on the newer generate-ice-servers
    // route, which we deliberately do not use).
    private sealed record GenerateResponse([property: JsonPropertyName("iceServers")] IceServers? IceServers);

    private sealed record IceServers(
        [property: JsonPropertyName("urls")] string[]? Urls,
        [property: JsonPropertyName("username")] string? Username,
        [property: JsonPropertyName("credential")] string? Credential);
}
