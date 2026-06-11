// ---------------------------------------------------------------------------
// FcmTokenProvider.cs — OAuth2 access tokens for the FCM HTTP v1 API
// ---------------------------------------------------------------------------
// The FCM HTTP v1 API (the only one Google still operates — the legacy
// server-key API was shut down in June 2024) authenticates with short-lived
// OAuth2 access tokens instead of a static server key.
//
// The flow is the standard Google "service account" two-legged OAuth:
//   1. Build a JWT assertion signed with the service account's RSA private key
//      (RS256). Claims: iss = service account email, scope = firebase.messaging,
//      aud = Google's token endpoint, iat/exp = now / now + 1 hour.
//   2. POST the assertion to the token endpoint
//      (grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer).
//   3. Receive { access_token, expires_in } — the access token is then used
//      as a Bearer header on messages:send calls.
//
// We implement this directly (~100 lines) instead of pulling in the
// FirebaseAdmin SDK, which drags a large dependency tree for what is a
// single token exchange + one POST endpoint.
//
// Configuration: Push:FcmServiceAccountJson holds the *entire* service
// account JSON file (downloaded from Firebase console → Project settings →
// Service accounts). Passing the whole JSON as one config value makes it easy
// to inject as a single secret (env var / Key Vault) without extracting fields.
//
// Registered as a singleton: the parsed key and the cached access token are
// shared across all push sends. Token caching matters — Google rate-limits
// the token endpoint, and tokens are valid for an hour.
// ---------------------------------------------------------------------------

using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;

namespace CallType.Api.Services;

public class FcmTokenProvider : IDisposable
{
    /// <summary>OAuth scope required for FCM HTTP v1 sends.</summary>
    private const string FcmScope = "https://www.googleapis.com/auth/firebase.messaging";

    /// <summary>
    /// Refresh the cached token this long before its actual expiry, so a token
    /// that is "about to expire" is never used for an outgoing request.
    /// </summary>
    private static readonly TimeSpan ExpiryMargin = TimeSpan.FromMinutes(5);

    private readonly IHttpClientFactory _httpFactory;
    private readonly ILogger<FcmTokenProvider> _logger;

    // Parsed from the service account JSON. All null when push is not configured.
    private readonly string? _clientEmail;
    private readonly string? _tokenUri;
    private readonly RSA? _privateKey;

    // Access token cache. Guarded by _refreshLock so concurrent pushes do not
    // trigger parallel token exchanges.
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private string? _cachedToken;
    private DateTimeOffset _cachedTokenExpiresAt;

    /// <summary>True when a service account is configured and pushes can be sent.</summary>
    public bool IsConfigured => _clientEmail is not null;

    /// <summary>Firebase project id — part of the messages:send URL.</summary>
    public string? ProjectId { get; }

    public FcmTokenProvider(
        IHttpClientFactory httpFactory,
        IConfiguration config,
        ILogger<FcmTokenProvider> logger)
    {
        _httpFactory = httpFactory;
        _logger = logger;

        var serviceAccountJson = config["Push:FcmServiceAccountJson"];
        if (string.IsNullOrWhiteSpace(serviceAccountJson))
        {
            // Push not configured — valid for local dev and tests. The push
            // service checks IsConfigured and skips sends with a warning.
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(serviceAccountJson);
            var root = doc.RootElement;

            _clientEmail = root.GetProperty("client_email").GetString();
            ProjectId = root.GetProperty("project_id").GetString();

            // token_uri is present in every service account file, but default
            // to Google's well-known endpoint just in case.
            _tokenUri = root.TryGetProperty("token_uri", out var uri)
                ? uri.GetString()
                : "https://oauth2.googleapis.com/token";

            // The private key is PKCS#8 PEM ("BEGIN PRIVATE KEY").
            // The RSA instance lives as long as this singleton — disposed in Dispose().
            _privateKey = RSA.Create();
            _privateKey.ImportFromPem(root.GetProperty("private_key").GetString());
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException
            or ArgumentException or CryptographicException)
        {
            // A malformed service account must not take the whole API down —
            // push is an optional subsystem. Log loudly and run unconfigured.
            _logger.LogError(ex,
                "Push:FcmServiceAccountJson is set but could not be parsed — push notifications are DISABLED");
            _privateKey?.Dispose();
            _privateKey = null;
            _clientEmail = null;
            ProjectId = null;
        }
    }

    /// <summary>
    /// Returns a valid OAuth2 access token for FCM, using the cached one when
    /// it still has at least <see cref="ExpiryMargin"/> of lifetime left.
    /// </summary>
    /// <exception cref="InvalidOperationException">Provider is not configured.</exception>
    /// <exception cref="HttpRequestException">Token endpoint returned an error.</exception>
    public async Task<string> GetAccessTokenAsync(CancellationToken ct = default)
    {
        if (!IsConfigured)
            throw new InvalidOperationException("FCM service account is not configured.");

        // Fast path — token still fresh. Reading the two fields without the lock
        // is safe: worst case we read a stale pair and fall through to the lock.
        if (_cachedToken is not null && DateTimeOffset.UtcNow < _cachedTokenExpiresAt - ExpiryMargin)
            return _cachedToken;

        await _refreshLock.WaitAsync(ct);
        try
        {
            // Re-check after acquiring the lock — another caller may have
            // refreshed the token while we were waiting.
            if (_cachedToken is not null && DateTimeOffset.UtcNow < _cachedTokenExpiresAt - ExpiryMargin)
                return _cachedToken;

            var now = DateTimeOffset.UtcNow;
            var assertion = CreateSignedAssertion(now);

            var client = _httpFactory.CreateClient();
            using var response = await client.PostAsync(
                _tokenUri,
                new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"] = "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    ["assertion"] = assertion
                }),
                ct);

            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(ct);
                throw new HttpRequestException(
                    $"FCM token exchange failed with {(int)response.StatusCode}: {body}");
            }

            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
            var token = doc.RootElement.GetProperty("access_token").GetString()
                ?? throw new HttpRequestException("FCM token response contained no access_token.");
            var expiresIn = doc.RootElement.GetProperty("expires_in").GetInt32();

            _cachedToken = token;
            _cachedTokenExpiresAt = now.AddSeconds(expiresIn);
            return token;
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    /// <summary>
    /// Builds the RS256-signed JWT assertion for the OAuth token exchange.
    /// Internal so unit tests can verify the claims and signature directly
    /// without hitting the token endpoint.
    /// </summary>
    internal string CreateSignedAssertion(DateTimeOffset now)
    {
        if (_privateKey is null || _clientEmail is null || _tokenUri is null)
            throw new InvalidOperationException("FCM service account is not configured.");

        var claims = new[]
        {
            // "scope" is a Google-specific claim — which APIs the resulting
            // access token may call.
            new Claim("scope", FcmScope),
            new Claim(JwtRegisteredClaimNames.Iat, now.ToUnixTimeSeconds().ToString(),
                ClaimValueTypes.Integer64)
        };

        var credentials = new SigningCredentials(
            new RsaSecurityKey(_privateKey), SecurityAlgorithms.RsaSha256);

        var token = new JwtSecurityToken(
            issuer: _clientEmail,         // who is asking = the service account
            audience: _tokenUri,          // who the assertion is for = token endpoint
            claims: claims,
            notBefore: now.UtcDateTime,
            // Google caps assertion lifetime at 1 hour.
            expires: now.AddHours(1).UtcDateTime,
            signingCredentials: credentials);

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    public void Dispose()
    {
        _privateKey?.Dispose();
        _refreshLock.Dispose();
        GC.SuppressFinalize(this);
    }
}
