// ---------------------------------------------------------------------------
// Program.cs — Application entry point for ZMessanger API
// ---------------------------------------------------------------------------
// Minimal API host with a /health endpoint. Future tasks will add SignalR,
// authentication, and domain-specific routes on top of this skeleton.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Endpoints;
using ZMessanger.Api.Hubs;
using ZMessanger.Api.Services;

var builder = WebApplication.CreateBuilder(args);

// Register EF Core with Npgsql. The connection string is read from
// configuration so it can be overridden per environment (and by
// WebApplicationFactory in integration tests using Testcontainers).
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("DefaultConnection")));

// MessageQueueService is scoped (one instance per request/hub invocation)
// because it depends on the scoped AppDbContext.
builder.Services.AddScoped<MessageQueueService>();

// SignalR is the real-time transport for message relay, typing indicators,
// and WebRTC call signaling. Called explicitly for clarity even though the
// shared framework may include it.
builder.Services.AddSignalR();

var app = builder.Build();

// Health-check endpoint — lightweight probe for orchestrators (k8s, Azure App
// Service) and integration tests. Returns 200 with a JSON body so callers can
// verify both connectivity and basic serialization.
// Property is lowercase because ASP.NET Core's default System.Text.Json
// serialization uses camelCase — standard REST/JSON convention.
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.MapDeviceEndpoints();

// Map the SignalR hub at /hub. Clients connect with a deviceId query param:
// ws://host/hub?deviceId=<guid>
app.MapHub<MessengerHub>("/hub");

app.Run();

// ---------------------------------------------------------------------------
// Partial class declaration makes the compiler-generated Program type visible
// to the test project via InternalsVisibleTo, which is required by
// WebApplicationFactory<Program> to discover the entry point assembly.
// ---------------------------------------------------------------------------
public partial class Program { }
