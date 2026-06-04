// ---------------------------------------------------------------------------
// Program.cs — Application entry point for CallType API
// ---------------------------------------------------------------------------
// Minimal API host with JWT authentication, health check, device/account/
// group/backup endpoints, TURN credential generation, a SignalR hub for
// real-time encrypted message relay, and background expired message cleanup.
// ---------------------------------------------------------------------------

using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using CallType.Api.Data;
using CallType.Api.Endpoints;
using CallType.Api.Hubs;
using CallType.Api.Services;

var builder = WebApplication.CreateBuilder(args);

// Register EF Core with Npgsql. The connection string is read from
// configuration so it can be overridden per environment (and by
// WebApplicationFactory in integration tests using Testcontainers).
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("DefaultConnection")));

// MessageQueueService is scoped (one instance per request/hub invocation)
// because it depends on the scoped AppDbContext.
builder.Services.AddScoped<MessageQueueService>();

// TurnCredentialService is a singleton — it is stateless (reads config once,
// computes HMACs). No DbContext dependency, so no scoping needed.
builder.Services.AddSingleton<TurnCredentialService>();

// JwtService is a singleton — reads config once, generates/validates tokens.
// No DbContext dependency, no mutable state.
builder.Services.AddSingleton<JwtService>();

// MessageCleanupService runs hourly to bulk-delete expired queued messages.
// Prevents unbounded storage growth from abandoned devices that never reconnect.
builder.Services.AddHostedService<MessageCleanupService>();

// --- JWT Bearer Authentication -------------------------------------------
// All endpoints except health, device registration, and auth/token require
// a valid JWT. The token is issued by POST /auth/token after the device
// proves it holds the secret received at registration.
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        var jwtSecret = builder.Configuration["Jwt:Secret"]
            ?? throw new InvalidOperationException("Jwt:Secret is not configured.");

        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = builder.Configuration["Jwt:Issuer"] ?? "CallType.Api",
            // No audience claim in our tokens — single-API system.
            ValidateAudience = false,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtSecret)),
            ValidateLifetime = true,
            // Zero clock skew — we control both sides (API issues + validates).
            // Avoids the default 5-minute window that would extend token lifetime.
            ClockSkew = TimeSpan.Zero
        };

        // SignalR sends the JWT as a query string parameter during the WebSocket
        // upgrade handshake because WebSocket does not support custom HTTP headers.
        // We intercept the handshake and move the token into the context so the
        // standard JWT middleware can validate it.
        options.Events = new JwtBearerEvents
        {
            OnMessageReceived = context =>
            {
                var accessToken = context.Request.Query["access_token"];
                var path = context.HttpContext.Request.Path;

                // Only extract from query string for SignalR hub paths.
                if (!string.IsNullOrEmpty(accessToken) && path.StartsWithSegments("/hub"))
                {
                    context.Token = accessToken;
                }

                return Task.CompletedTask;
            }
        };
    });

builder.Services.AddAuthorization();

// SignalR is the real-time transport for message relay, typing indicators,
// and WebRTC call signaling. Called explicitly for clarity even though the
// shared framework may include it.
builder.Services.AddSignalR();

var app = builder.Build();

// Authentication and authorization middleware must run before endpoint routing
// so that [Authorize] attributes and RequireAuthorization() are enforced.
app.UseAuthentication();
app.UseAuthorization();

// Health-check endpoint — lightweight probe for orchestrators (k8s, Azure App
// Service) and integration tests. Returns 200 with a JSON body so callers can
// verify both connectivity and basic serialization.
// AllowAnonymous: health checks must work without authentication so
// orchestrators can probe without credentials.
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }))
    .AllowAnonymous();

// Auth endpoints are public — they ARE the authentication mechanism.
app.MapAuthEndpoints();

app.MapDeviceEndpoints();
app.MapAccountEndpoints();
app.MapGroupEndpoints();
app.MapBackupEndpoints();
app.MapTurnCredentialEndpoints();

// Map the SignalR hub at /hub. The hub is protected by [Authorize] — clients
// must pass access_token as a query parameter during the WebSocket upgrade.
app.MapHub<MessengerHub>("/hub");

app.Run();

// ---------------------------------------------------------------------------
// Partial class declaration makes the compiler-generated Program type visible
// to the test project via InternalsVisibleTo, which is required by
// WebApplicationFactory<Program> to discover the entry point assembly.
// ---------------------------------------------------------------------------
public partial class Program { }
