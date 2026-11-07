using System.Net;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using FluentAssertions;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class RateLimitTests : IntegrationTestBase
{
    [Fact]
    public async Task Auth_budget_is_per_remote_ip_and_ignores_forwarded_headers()
    {
        async Task<int> Login(string ip, string forwarded)
        {
            var body = System.Text.Encoding.UTF8.GetBytes("{\"email\":\"\",\"authKey\":\"\"}");
            var result = await Factory.Server.SendAsync(context => {
                context.Connection.RemoteIpAddress = IPAddress.Parse(ip);
                context.Request.Method = "POST";
                context.Request.Path = "/accounts/login";
                context.Request.ContentType = "application/json";
                context.Request.ContentLength = body.Length;
                context.Request.Body = new MemoryStream(body);
                context.Request.Headers["X-Forwarded-For"] = forwarded;
            });
            return result.Response.StatusCode;
        }
        for (var i = 0; i < 10; i++)
            (await Login("192.0.2.1", $"198.51.100.{i + 1}")).Should().Be(400);
        (await Login("192.0.2.1", "203.0.113.1")).Should().Be(429);
        (await Login("192.0.2.2", "203.0.113.1")).Should().Be(400);
    }

    [Fact]
    public async Task One_device_cannot_exhaust_another_devices_api_budget()
    {
        var (_, firstToken, _) = await RegisterAndAuthenticateAsync();
        var (_, secondToken, _) = await RegisterAndAuthenticateAsync();
        Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", firstToken);
        var path = $"/groups/{Guid.NewGuid()}/members";
        // Bursts of 110 concurrent requests (budget is 100/min). Sequential
        // requests took ~1.4 s each on a slow CI runner, so even 205 of them
        // spread over several fixed one-minute windows and never hit 429. A
        // burst lands in one window; the retry covers a burst that happens
        // to straddle a window boundary.
        var limited = false;
        for (var burst = 0; burst < 3 && !limited; burst++)
        {
            var responses = await Task.WhenAll(Enumerable.Range(0, 110).Select(_ => Client.GetAsync(path)));
            limited = responses.Any(r => r.StatusCode == HttpStatusCode.TooManyRequests);
            foreach (var response in responses) response.Dispose();
        }
        limited.Should().BeTrue("110 requests at once exceed the 100/min api budget");
        Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", secondToken);
        (await Client.GetAsync(path)).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
    [Fact]
    public async Task Configured_proxy_is_trusted_but_other_sources_cannot_spoof_their_budget()
    {
        await using var proxied = Factory.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, config) =>
            config.AddInMemoryCollection(new Dictionary<string, string?> { ["Proxy:KnownProxy"] = "172.30.0.10" })));
        using var client = proxied.CreateClient();
        async Task<int> Login(string remote, string forwarded)
        {
            var body = System.Text.Encoding.UTF8.GetBytes("{\"email\":\"\",\"authKey\":\"\"}");
            var result = await proxied.Server.SendAsync(context => {
                context.Connection.RemoteIpAddress = IPAddress.Parse(remote);
                context.Request.Method = "POST";
                context.Request.Path = "/accounts/login";
                context.Request.ContentType = "application/json";
                context.Request.ContentLength = body.Length;
                context.Request.Body = new MemoryStream(body);
                context.Request.Headers["X-Forwarded-For"] = forwarded;
                context.Request.Headers["X-Forwarded-Proto"] = "https";
            });
            return result.Response.StatusCode;
        }
        // 11 concurrent logins against the 10/min login budget. Sequential
        // calls took ~10 s each on a slow CI runner, so 11 of them spread over
        // two fixed one-minute windows and the 11th got 400 instead of 429. A
        // burst lands in one window; the retry covers a burst that straddles
        // a window boundary.
        async Task<bool> BurstIsLimited(string remote, Func<int, string> forwarded)
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                var codes = await Task.WhenAll(Enumerable.Range(0, 11).Select(i => Login(remote, forwarded(i))));
                codes.Should().OnlyContain(code => code == 400 || code == 429);
                if (codes.Contains(429)) return true;
            }
            return false;
        }
        // An untrusted source shares one budget whatever X-Forwarded-For says.
        (await BurstIsLimited("192.0.2.1", i => $"198.51.100.{i + 1}")).Should().BeTrue();
        // Behind the trusted proxy the forwarded client gets its own budget.
        (await BurstIsLimited("172.30.0.10", _ => "203.0.113.1")).Should().BeTrue();
        (await Login("172.30.0.10", "203.0.113.2")).Should().Be(400);
    }

    [Fact]
    public async Task Hub_access_token_never_appears_in_logs_on_failed_authentication()
    {
        // Marker doubles as a fake JWT and as the string we scan for — if it
        // ever leaks into a log line (auth failure, exception, or otherwise),
        // this test fails regardless of which component logged it.
        const string tokenMarker = "SECRET_TOKEN_MARKER_never_should_be_logged";
        var sink = new CapturingLoggerProvider();

        await using var logged = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureServices(services => services.AddSingleton<ILoggerProvider>(sink)));
        using var client = logged.CreateClient();

        // Invalid token against the SignalR negotiate endpoint — exercises the
        // same OnMessageReceived query-string extraction path as /hub, without
        // needing a full WebSocket handshake.
        var response = await client.PostAsync($"/hub/negotiate?access_token={tokenMarker}", content: null);

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        sink.Messages.Should().NotContain(m => m.Contains(tokenMarker));
    }

    /// <summary>Captures every formatted log message (and exception text) so tests can assert secrets never appear in them.</summary>
    private sealed class CapturingLoggerProvider : ILoggerProvider
    {
        public ConcurrentBag<string> Messages { get; } = new();

        public ILogger CreateLogger(string categoryName) => new CapturingLogger(Messages);

        public void Dispose() { }

        private sealed class CapturingLogger(ConcurrentBag<string> messages) : ILogger
        {
            public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
            public bool IsEnabled(LogLevel logLevel) => true;

            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
                Func<TState, Exception?, string> formatter)
            {
                messages.Add(formatter(state, exception));
                if (exception is not null)
                    messages.Add(exception.ToString());
            }
        }
    }
}
