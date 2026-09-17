// ---------------------------------------------------------------------------
// ChannelRoutesTests.cs — DB-free smoke test of the channel route table
// ---------------------------------------------------------------------------
// Minimal API builds its request delegates lazily on the first request, so a
// handler signature the framework cannot bind (or two ambiguous routes) only
// blows up at runtime. This test boots the real pipeline WITHOUT PostgreSQL or
// Docker and proves (a) every channel route can be built and matched and
// (b) none of them is reachable without a JWT — authorization rejects the
// request before any handler (and therefore the database) is touched.
// ---------------------------------------------------------------------------

using System.Net;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace CallType.Api.Tests.Endpoints;

public class ChannelRoutesTests
{
    [Theory]
    [InlineData("POST", "/channels")]
    [InlineData("GET", "/channels/mine")]
    [InlineData("GET", "/channels/CH-ABCD-EFGH")]
    [InlineData("PATCH", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff")]
    [InlineData("DELETE", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff")]
    [InlineData("GET", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/admins")]
    [InlineData("PUT", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/admins/6f9619ff-8b86-d011-b42d-00cf4fc964fe")]
    [InlineData("DELETE", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/admins/6f9619ff-8b86-d011-b42d-00cf4fc964fe")]
    [InlineData("POST", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/follow")]
    [InlineData("DELETE", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/follow")]
    [InlineData("POST", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/posts")]
    [InlineData("GET", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/posts?after=2026-09-17T12:00:00Z&limit=10")]
    [InlineData("DELETE", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/posts/6f9619ff-8b86-d011-b42d-00cf4fc964fe")]
    [InlineData("PUT", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/posts/6f9619ff-8b86-d011-b42d-00cf4fc964fe/reaction")]
    [InlineData("DELETE", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/posts/6f9619ff-8b86-d011-b42d-00cf4fc964fe/reaction")]
    [InlineData("PUT", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/posts/6f9619ff-8b86-d011-b42d-00cf4fc964fe/vote")]
    [InlineData("POST", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/report")]
    [InlineData("POST", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/attachments")]
    [InlineData("GET", "/channels/6f9619ff-8b86-d011-b42d-00cf4fc964ff/attachments/0123456789abcdef0123456789abcdef.png")]
    public async Task Channel_route_exists_and_requires_a_token(string method, string url)
    {
        await using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(
                new Dictionary<string, string?> { ["Jwt:Secret"] = "test-jwt-secret-at-least-32-characters-long!!" })));
        using var client = factory.CreateClient();

        using var response = await client.SendAsync(new HttpRequestMessage(new HttpMethod(method), url));

        // 401 (not 404/405) = the route matched; (not 500) = its delegate could be built.
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }
}
