// ---------------------------------------------------------------------------
// HealthCheckTests.cs — Integration tests for /health and /health/ready
// ---------------------------------------------------------------------------
// Liveness (/health) must stay 200 even when dependencies are down — it
// answers "is the process alive", not "are its dependencies healthy".
// Readiness (/health/ready) is the opposite: 200 only when PostgreSQL and
// the backup Blob container are both reachable (K05). Uses
// IntegrationTestBase so /health/ready has real containers to check against;
// the down-dependency cases point a second host at a broken connection
// string instead of tearing down the shared containers mid-suite.
// ---------------------------------------------------------------------------

using System.Net;
using System.Text.Json;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Microsoft.Extensions.Configuration;

namespace CallType.Api.Tests;

public class HealthCheckTests : IntegrationTestBase
{
    [Fact]
    public async Task Health_endpoint_returns_200_OK()
    {
        var response = await Client.GetAsync("/health");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Health_endpoint_returns_healthy_status_in_body()
    {
        var response = await Client.GetAsync("/health");
        var content = await response.Content.ReadAsStringAsync();

        using var doc = JsonDocument.Parse(content);
        doc.RootElement.GetProperty("status").GetString().Should().Be("healthy");
    }

    [Fact]
    public async Task Ready_endpoint_returns_200_when_postgres_and_blob_are_reachable()
    {
        var response = await Client.GetAsync("/health/ready");
        var content = await response.Content.ReadAsStringAsync();

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        using var doc = JsonDocument.Parse(content);
        doc.RootElement.GetProperty("status").GetString().Should().Be("ready");
    }

    [Fact]
    public async Task Ready_endpoint_returns_503_when_postgres_is_unreachable()
    {
        // A syntactically valid but unroutable connection string simulates
        // PostgreSQL being down without tearing down the shared container
        // that other tests in this run still depend on.
        await using var brokenDb = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:DefaultConnection"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=1"
            })));
        using var client = brokenDb.CreateClient();

        var response = await client.GetAsync("/health/ready");
        var content = await response.Content.ReadAsStringAsync();

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        using var doc = JsonDocument.Parse(content);
        doc.RootElement.GetProperty("status").GetString().Should().Be("not_ready");
        // Body must never leak addresses or exception details.
        content.Should().NotContain("127.0.0.1");
        content.Should().NotContain("Exception");
    }

    [Fact]
    public async Task Ready_endpoint_returns_503_when_blob_storage_is_unreachable()
    {
        await using var brokenBlob = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                // Well-formed connection string pointing at a port nothing listens on.
                ["ConnectionStrings:BlobStorage"] =
                    "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:1/devstoreaccount1"
            })));
        using var client = brokenBlob.CreateClient();

        var response = await client.GetAsync("/health/ready");

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
    }

    [Fact]
    public async Task Health_endpoint_stays_200_when_dependencies_are_down()
    {
        await using var brokenDb = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:DefaultConnection"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=1"
            })));
        using var client = brokenDb.CreateClient();

        (await client.GetAsync("/health")).StatusCode.Should().Be(HttpStatusCode.OK);
    }
}
