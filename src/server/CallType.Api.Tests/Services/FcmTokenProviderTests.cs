// ---------------------------------------------------------------------------
// FcmTokenProviderTests.cs — Unit tests for the FCM OAuth2 token provider
// ---------------------------------------------------------------------------
// Pure unit tests (no Testcontainers, no real network). We generate a real
// RSA key pair so the provider signs real RS256 assertions, then verify:
// 1. Unconfigured / malformed service account JSON disables the provider
//    without throwing (push is optional — a bad secret must not kill the API).
// 2. The signed assertion carries the claims Google's token endpoint expects
//    (iss = service account email, aud = token endpoint, scope = FCM) and
//    its signature validates against the public key.
// 3. The token exchange parses Google's response and caches the access token —
//    repeated calls must not hit the token endpoint again while fresh.
// The HTTP layer is faked with a stub HttpMessageHandler injected through a
// minimal IHttpClientFactory implementation.
// ---------------------------------------------------------------------------

using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.IdentityModel.Tokens;
using CallType.Api.Services;

namespace CallType.Api.Tests.Services;

public class FcmTokenProviderTests
{
    private const string TokenUri = "https://oauth2.googleapis.com/token";
    private const string ClientEmail = "push@test-project.iam.gserviceaccount.com";

    /// <summary>
    /// Builds a syntactically valid Google service account JSON around a
    /// freshly generated RSA key. The caller keeps the RSA instance to verify
    /// signatures against the matching public key.
    /// </summary>
    private static string CreateServiceAccountJson(RSA rsa) => JsonSerializer.Serialize(new
    {
        type = "service_account",
        project_id = "test-project",
        private_key = rsa.ExportPkcs8PrivateKeyPem(),
        client_email = ClientEmail,
        token_uri = TokenUri
    });

    private static IConfiguration BuildConfig(string? serviceAccountJson) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Push:FcmServiceAccountJson"] = serviceAccountJson
            })
            .Build();

    private static FcmTokenProvider CreateProvider(
        string? serviceAccountJson, HttpMessageHandler? handler = null)
    {
        return new FcmTokenProvider(
            new StubHttpClientFactory(handler ?? new StubHttpMessageHandler()),
            BuildConfig(serviceAccountJson),
            NullLogger<FcmTokenProvider>.Instance);
    }

    [Fact]
    public void Provider_is_not_configured_without_service_account()
    {
        using var provider = CreateProvider(serviceAccountJson: null);

        provider.IsConfigured.Should().BeFalse();
        provider.ProjectId.Should().BeNull();
    }

    [Fact]
    public async Task GetAccessTokenAsync_throws_when_not_configured()
    {
        using var provider = CreateProvider(serviceAccountJson: null);

        var act = () => provider.GetAccessTokenAsync();

        await act.Should().ThrowAsync<InvalidOperationException>();
    }

    [Fact]
    public void Malformed_service_account_json_disables_provider_instead_of_throwing()
    {
        // A bad secret value (truncated JSON, wrong key format…) must degrade
        // to "push disabled", never crash application startup.
        using var provider = CreateProvider("{ \"project_id\": \"x\", not valid json");

        provider.IsConfigured.Should().BeFalse();
    }

    [Fact]
    public void Service_account_with_invalid_private_key_disables_provider()
    {
        var json = JsonSerializer.Serialize(new
        {
            type = "service_account",
            project_id = "test-project",
            private_key = "-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----\n",
            client_email = ClientEmail,
            token_uri = TokenUri
        });

        using var provider = CreateProvider(json);

        provider.IsConfigured.Should().BeFalse();
    }

    [Fact]
    public void CreateSignedAssertion_produces_rs256_jwt_with_google_oauth_claims()
    {
        using var rsa = RSA.Create(2048);
        using var provider = CreateProvider(CreateServiceAccountJson(rsa));
        var now = DateTimeOffset.UtcNow;

        var assertion = provider.CreateSignedAssertion(now);

        // Validate the signature with the matching public key and check the
        // claims Google's token endpoint requires.
        var handler = new JwtSecurityTokenHandler();
        var principal = handler.ValidateToken(assertion, new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = ClientEmail,
            ValidateAudience = true,
            ValidAudience = TokenUri,
            IssuerSigningKey = new RsaSecurityKey(rsa.ExportParameters(false)),
            ValidateLifetime = true
        }, out var validatedToken);

        var jwt = (JwtSecurityToken)validatedToken;
        jwt.Header.Alg.Should().Be(SecurityAlgorithms.RsaSha256);
        principal.Claims.Should().Contain(c =>
            c.Type == "scope" && c.Value == "https://www.googleapis.com/auth/firebase.messaging");
        // Google caps assertion lifetime at 1 hour.
        jwt.ValidTo.Should().BeCloseTo(now.UtcDateTime.AddHours(1), TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task GetAccessTokenAsync_exchanges_assertion_and_caches_token()
    {
        using var rsa = RSA.Create(2048);
        var handler = new StubHttpMessageHandler
        {
            Respond = async request =>
            {
                request.RequestUri!.ToString().Should().Be(TokenUri);
                var form = await request.Content!.ReadAsStringAsync();
                form.Should().Contain("grant_type=");
                form.Should().Contain("assertion=");

                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(
                        """{"access_token":"test-access-token","expires_in":3600,"token_type":"Bearer"}""")
                };
            }
        };
        using var provider = CreateProvider(CreateServiceAccountJson(rsa), handler);

        var token1 = await provider.GetAccessTokenAsync();
        var token2 = await provider.GetAccessTokenAsync();

        token1.Should().Be("test-access-token");
        token2.Should().Be("test-access-token");
        // The second call must come from the cache — tokens live ~1 hour and
        // Google rate-limits the token endpoint.
        handler.RequestCount.Should().Be(1);
    }

    [Fact]
    public async Task GetAccessTokenAsync_throws_on_token_endpoint_error()
    {
        using var rsa = RSA.Create(2048);
        var handler = new StubHttpMessageHandler
        {
            Respond = _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest)
            {
                Content = new StringContent("""{"error":"invalid_grant"}""")
            })
        };
        using var provider = CreateProvider(CreateServiceAccountJson(rsa), handler);

        var act = () => provider.GetAccessTokenAsync();

        await act.Should().ThrowAsync<HttpRequestException>();
    }

    // --- Test doubles -------------------------------------------------------

    /// <summary>Minimal IHttpClientFactory returning clients over a fixed handler.</summary>
    private sealed class StubHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    /// <summary>Programmable HttpMessageHandler counting outgoing requests.</summary>
    private sealed class StubHttpMessageHandler : HttpMessageHandler
    {
        public int RequestCount { get; private set; }

        public Func<HttpRequestMessage, Task<HttpResponseMessage>> Respond { get; set; } =
            _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestCount++;
            return Respond(request);
        }
    }
}
