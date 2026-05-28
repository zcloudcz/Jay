// ---------------------------------------------------------------------------
// Program.cs — Application entry point for ZMessanger API
// ---------------------------------------------------------------------------
// Minimal API host with a /health endpoint. Future tasks will add SignalR,
// EF Core, authentication, and domain-specific routes on top of this skeleton.
// ---------------------------------------------------------------------------

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// Health-check endpoint — lightweight probe for orchestrators (k8s, Azure App
// Service) and integration tests. Returns 200 with a JSON body so callers can
// verify both connectivity and basic serialization.
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.Run();

// ---------------------------------------------------------------------------
// Partial class declaration makes the compiler-generated Program type visible
// to the test project via InternalsVisibleTo, which is required by
// WebApplicationFactory<Program> to discover the entry point assembly.
// ---------------------------------------------------------------------------
public partial class Program { }
