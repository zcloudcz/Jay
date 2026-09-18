// ---------------------------------------------------------------------------
// SecurityTxtEndpointsTests.cs — GET /.well-known/security.txt (N04)
// ---------------------------------------------------------------------------

using System.Net;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class SecurityTxtEndpointsTests : IntegrationTestBase
{
    [Fact]
    public async Task Returns_404_when_no_contact_is_configured()
    {
        // Base factory carries no Security:ContactUri — better no security.txt
        // than a wrong one.
        var response = await Client.GetAsync("/.well-known/security.txt");
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Returns_200_text_plain_with_contact_and_future_expires_when_configured()
    {
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["Security:ContactUri"] = "mailto:security@example.invalid",
                })));
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/.well-known/security.txt");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        response.Content.Headers.ContentType?.MediaType.Should().Be("text/plain");
        var body = await response.Content.ReadAsStringAsync();
        body.Should().Contain("Contact: mailto:security@example.invalid");
        body.Should().Contain("Preferred-Languages: cs, en");

        var expiresLine = body.Split('\n').Single(line => line.StartsWith("Expires:"));
        var expires = DateTimeOffset.Parse(expiresLine["Expires:".Length..].Trim());
        expires.Should().BeAfter(DateTimeOffset.UtcNow.AddMonths(6), "Expires must be roughly a year out, not in the past");
    }
}
