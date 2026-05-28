// ---------------------------------------------------------------------------
// HealthCheckTests.cs — Integration tests for the /health endpoint
// ---------------------------------------------------------------------------
// Uses WebApplicationFactory to spin up the real ASP.NET Core pipeline
// in-memory, ensuring the health endpoint is wired correctly end-to-end
// (routing, serialization, status code).
// ---------------------------------------------------------------------------

using System.Net;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;

namespace ZMessanger.Api.Tests;

public class HealthCheckTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public HealthCheckTests(WebApplicationFactory<Program> factory)
    {
        // CreateClient starts the test server; no real port is opened.
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task Health_endpoint_returns_200_OK()
    {
        var response = await _client.GetAsync("/health");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Health_endpoint_returns_healthy_status_in_body()
    {
        var response = await _client.GetAsync("/health");
        var content = await response.Content.ReadAsStringAsync();

        // Deserialize and verify the JSON payload matches the expected shape.
        using var doc = JsonDocument.Parse(content);
        var status = doc.RootElement.GetProperty("status").GetString();

        status.Should().Be("healthy");
    }
}
