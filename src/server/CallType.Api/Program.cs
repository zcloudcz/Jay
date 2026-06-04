// ---------------------------------------------------------------------------
// Program.cs — Application entry point for CallType API
// ---------------------------------------------------------------------------
// Minimal API host with JWT authentication, CORS, rate limiting, health check,
// device/account/group/backup endpoints, TURN credential generation, a SignalR
// hub for real-time encrypted message relay, and background expired message
// cleanup.
// ---------------------------------------------------------------------------

using System.Text;
using System.Threading.RateLimiting;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using CallType.Api.Data;
using CallType.Api.Endpoints;
using CallType.Api.Hubs;
using CallType.Api.Services;

var builder = WebApplication.CreateBuilder(args);

// --- Request size limit -----------------------------------------------------
// 10 MB cap on request bodies. Prevents abuse (huge uploads) and protects
// Kestrel memory. Backup uploads are expected to be under this — larger
// backups should be split client-side.
builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = 10 * 1024 * 1024; // 10 MB
});

// Register EF Core with Npgsql. The connection string is read from
// configuration so it can be overridden per environment (and by
// WebApplicationFactory in integration tests using Testcontainers).
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("DefaultConnection")));

// MessageQueueService is scoped (one instance per request/hub invocation)
// because it depends on the scoped AppDbContext.
builder.Services.AddScoped<MessageQueueService>();

// PushNotificationService is a singleton — it is stateless (reads config once)
// and uses IServiceScopeFactory to create short-lived DbContext scopes for
// device lookups. IHttpClientFactory provides pooled HttpClient instances.
builder.Services.AddHttpClient();
builder.Services.AddSingleton<PushNotificationService>();

// TurnCredentialService is a singleton — it is stateless (reads config once,
// computes HMACs). No DbContext dependency, so no scoping needed.
builder.Services.AddSingleton<TurnCredentialService>();

// JwtService is a singleton — reads config once, generates/validates tokens.
// No DbContext dependency, no mutable state.
builder.Services.AddSingleton<JwtService>();

// MessageCleanupService runs hourly to bulk-delete expired queued messages.
// Prevents unbounded storage growth from abandoned devices that never reconnect.
builder.Services.AddHostedService<MessageCleanupService>();

// BlobServiceClient for Azure Blob Storage — used by backup endpoints to upload
// and download encrypted backup files. Registered as singleton because the client
// is thread-safe and maintains an internal connection pool.
builder.Services.AddSingleton(_ =>
    new BlobServiceClient(builder.Configuration.GetConnectionString("BlobStorage")));

// --- CORS -------------------------------------------------------------------
// Required for browser-based clients (Flutter Web) and SignalR WebSocket
// connections. AllowCredentials is mandatory for SignalR because the WebSocket
// upgrade sends cookies/auth headers.
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        var allowedOrigins = builder.Configuration
            .GetSection("Cors:AllowedOrigins")
            .Get<string[]>();

        if (allowedOrigins is { Length: > 0 })
        {
            policy.WithOrigins(allowedOrigins);
        }
        else
        {
            // Development fallback — allow any localhost origin.
            // SetIsOriginAllowed covers any port (3000, 5185, 8080, etc.)
            // without enumerating them.
            policy.SetIsOriginAllowed(origin =>
                new Uri(origin).Host == "localhost");
        }

        policy.AllowAnyHeader()
              .AllowAnyMethod()
              .AllowCredentials(); // Required for SignalR
    });
});

// --- Rate Limiting ----------------------------------------------------------
// Two buckets: "api" for general endpoints (100 req/min) and "auth" for
// authentication endpoints (10 req/min). The auth limiter is stricter to
// slow down credential brute-force attempts.
builder.Services.AddRateLimiter(options =>
{
    options.AddFixedWindowLimiter("api", opt =>
    {
        opt.PermitLimit = 100;
        opt.Window = TimeSpan.FromMinutes(1);
    });

    options.AddFixedWindowLimiter("auth", opt =>
    {
        opt.PermitLimit = 10;
        opt.Window = TimeSpan.FromMinutes(1);
    });

    // 429 Too Many Requests — standard HTTP status for rate limiting.
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
});

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

// Middleware order matters:
// 1. CORS — must be before auth so preflight OPTIONS requests are handled
// 2. Rate limiter — reject abusive traffic before burning auth CPU
// 3. Authentication + Authorization
app.UseCors();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();

// Health-check endpoint — lightweight probe for orchestrators (k8s, Azure App
// Service) and integration tests. Returns 200 with a JSON body so callers can
// verify both connectivity and basic serialization.
// AllowAnonymous: health checks must work without authentication so
// orchestrators can probe without credentials.
app.MapGet("/health", () => Results.Ok(new { status = "healthy" }))
    .AllowAnonymous();

// Auth endpoints use the stricter "auth" rate limiter to slow down brute-force.
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
