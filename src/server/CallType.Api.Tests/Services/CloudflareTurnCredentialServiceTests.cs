// ---------------------------------------------------------------------------
// CloudflareTurnCredentialServiceTests.cs — Cloudflare TURN provider
// ---------------------------------------------------------------------------
// Pure unit tests (no DB, no network): the HttpClient is backed by a fake
// handler that records the outgoing request and returns canned responses.
// Verifies request shape (auth header, key id in URL, ttl body), response
// mapping, and that every failure mode surfaces as TurnUnavailableException
// without leaking the response body.
// ---------------------------------------------------------------------------

using System.Net;
using System.Text.Json;
using CallType.Api.Services;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

namespace CallType.Api.Tests.Services;

public class CloudflareTurnCredentialServiceTests
{
    private const string KeyId = "0123456789abcdef";
    private const string ApiToken = "test-cloudflare-api-token";

    private sealed class FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }
        public string? LastBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastRequest = request;
            LastBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            return respond(request);
        }
    }

    private sealed class FakeFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private static CloudflareTurnCredentialService CreateService(FakeHandler handler, int ttl = 3600, string? stun = null)
    {
        var values = new Dictionary<string, string?>
        {
            ["Turn:Provider"] = "cloudflare",
            ["Turn:Cloudflare:KeyId"] = KeyId,
            ["Turn:Cloudflare:ApiToken"] = ApiToken,
            ["Turn:TtlSeconds"] = ttl.ToString(),
        };
        if (stun is not null) values["Turn:StunUrls:0"] = stun;

        var config = new ConfigurationBuilder().AddInMemoryCollection(values).Build();
        return new CloudflareTurnCredentialService(
            new FakeFactory(handler), config, NullLogger<CloudflareTurnCredentialService>.Instance);
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json") };

    private const string SuccessBody = """
        {
          "iceServers": {
            "urls": [
              "stun:stun.cloudflare.com:3478",
              "turn:turn.cloudflare.com:3478?transport=udp",
              "turn:turn.cloudflare.com:3478?transport=tcp",
              "turns:turn.cloudflare.com:5349?transport=tcp"
            ],
            "username": "cf-user-abc",
            "credential": "cf-cred-xyz"
          }
        }
        """;

    [Fact]
    public async Task Issue_sends_bearer_token_key_id_and_ttl_and_maps_response()
    {
        var handler = new FakeHandler(_ => Json(HttpStatusCode.Created, SuccessBody));
        var service = CreateService(handler, ttl: 1800, stun: "stun:extra.example:3478");

        var result = await service.IssueAsync(Guid.NewGuid(), CancellationToken.None);

        handler.LastRequest!.Method.Should().Be(HttpMethod.Post);
        handler.LastRequest.RequestUri!.ToString()
            .Should().Be($"https://rtc.live.cloudflare.com/v1/turn/keys/{KeyId}/credentials/generate");
        handler.LastRequest.Headers.Authorization!.Scheme.Should().Be("Bearer");
        handler.LastRequest.Headers.Authorization.Parameter.Should().Be(ApiToken);
        JsonDocument.Parse(handler.LastBody!).RootElement.GetProperty("ttl").GetInt32().Should().Be(1800);

        result.Username.Should().Be("cf-user-abc");
        result.Credential.Should().Be("cf-cred-xyz");
        result.TtlSeconds.Should().Be(1800);
        result.Urls.Should().HaveCount(4).And.Contain("turns:turn.cloudflare.com:5349?transport=tcp");
        result.StunUrls.Should().Equal("stun:extra.example:3478");
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public async Task Non_success_status_throws_unavailable_without_body(HttpStatusCode status)
    {
        const string secretishBody = "{\"error\":\"token cf-secret-echo rejected\"}";
        var handler = new FakeHandler(_ => Json(status, secretishBody));
        var service = CreateService(handler);

        var act = () => service.IssueAsync(Guid.NewGuid(), CancellationToken.None);

        var ex = await act.Should().ThrowAsync<TurnUnavailableException>();
        ex.Which.Message.Should().NotContain("cf-secret-echo");
    }

    [Theory]
    [InlineData("not json at all")]
    [InlineData("{\"iceServers\":{\"urls\":[]}}")] // no username/credential
    [InlineData("{}")]
    public async Task Malformed_success_body_throws_unavailable(string body)
    {
        var handler = new FakeHandler(_ => Json(HttpStatusCode.OK, body));
        var service = CreateService(handler);

        var act = () => service.IssueAsync(Guid.NewGuid(), CancellationToken.None);

        await act.Should().ThrowAsync<TurnUnavailableException>();
    }

    [Fact]
    public async Task Network_failure_throws_unavailable()
    {
        var handler = new FakeHandler(_ => throw new HttpRequestException("connection refused"));
        var service = CreateService(handler);

        var act = () => service.IssueAsync(Guid.NewGuid(), CancellationToken.None);

        await act.Should().ThrowAsync<TurnUnavailableException>();
    }

    [Fact]
    public void Missing_key_id_or_token_fails_fast_at_construction()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["Turn:Cloudflare:KeyId"] = KeyId })
            .Build();

        var act = () => new CloudflareTurnCredentialService(
            new FakeFactory(new FakeHandler(_ => throw new InvalidOperationException())),
            config, NullLogger<CloudflareTurnCredentialService>.Instance);

        act.Should().Throw<InvalidOperationException>().WithMessage("*Turn:Cloudflare:ApiToken*");
    }
}
