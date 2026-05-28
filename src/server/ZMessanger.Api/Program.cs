// ---------------------------------------------------------------------------
// Program.cs — Application entry point for ZMessanger API
// ---------------------------------------------------------------------------
// Minimal API host with a /health endpoint. Future tasks will add SignalR,
// authentication, and domain-specific routes on top of this skeleton.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Endpoints;

var builder = WebApplication.CreateBuilder(args);

// Register EF Core with Npgsql. The connection string is read from
// configuration so it can be overridden per environment (and by
// WebApplicationFactory in integration tests using Testcontainers).
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("DefaultConnection")));

var app = builder.Build();

// Health-check endpoint — lightweight probe for orchestrators (k8s, Azure App
// Service) and integration tests. Returns 200 with a JSON body so callers can
// verify both connectivity and basic serialization.
// Property is lowercase because ASP.NET Core's default System.Text.Json
// serialization uses camelCase — standard REST/JSON convention.
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.MapDeviceEndpoints();

app.Run();

// ---------------------------------------------------------------------------
// Partial class declaration makes the compiler-generated Program type visible
// to the test project via InternalsVisibleTo, which is required by
// WebApplicationFactory<Program> to discover the entry point assembly.
// ---------------------------------------------------------------------------
public partial class Program { }
