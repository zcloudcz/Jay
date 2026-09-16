using System.Net;
using Microsoft.Extensions.Configuration;
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
        HttpStatusCode status = HttpStatusCode.OK;
        for (var i = 0; i < 105 && status != HttpStatusCode.TooManyRequests; i++)
        {
            using var response = await Client.GetAsync(path);
            status = response.StatusCode;
        }
        status.Should().Be(HttpStatusCode.TooManyRequests);
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
        for (var i = 0; i < 10; i++)
            (await Login("192.0.2.1", $"198.51.100.{i + 1}")).Should().Be(400);
        (await Login("192.0.2.1", "203.0.113.1")).Should().Be(429);
        for (var i = 0; i < 10; i++)
            (await Login("172.30.0.10", "203.0.113.1")).Should().Be(400);
        (await Login("172.30.0.10", "203.0.113.1")).Should().Be(429);
        (await Login("172.30.0.10", "203.0.113.2")).Should().Be(400);
    }}


