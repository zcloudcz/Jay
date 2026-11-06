// ---------------------------------------------------------------------------
// Program.cs — Application entry point for CallType API
// ---------------------------------------------------------------------------
// Minimal API host with JWT authentication, CORS, rate limiting, health check,
// device/account/group/backup endpoints, TURN credential generation, a SignalR
// hub for real-time encrypted message relay, and background expired message
// cleanup.
// ---------------------------------------------------------------------------

using System.Text;
using System.Net;
using Microsoft.AspNetCore.HttpOverrides;
using System.Security.Claims;
using System.Threading.RateLimiting;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Endpoints;
using CallType.Api.Hubs;
using CallType.Api.Services;
using CallType.Audit.Application;
using CallType.Audit.Infrastructure;

var builder = WebApplication.CreateBuilder(args);
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    if (!IPAddress.TryParse(builder.Configuration["Proxy:KnownProxy"], out var knownProxy)) return;
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.ForwardLimit = 1;
    options.KnownIPNetworks.Clear();
    options.KnownProxies.Clear();
    options.KnownProxies.Add(knownProxy);
});
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
builder.Services.AddScoped<DeviceListService>();
builder.Services.AddScoped<ConversationMuteService>();

// PushNotificationService is a singleton — it is stateless (reads config once)
// and uses IServiceScopeFactory to create short-lived DbContext scopes for
// device lookups. IHttpClientFactory provides pooled HttpClient instances.
// FcmTokenProvider is a singleton because it caches the OAuth2 access token
// for the FCM HTTP v1 API across all push sends (tokens are valid ~1 hour).
builder.Services.AddHttpClient();
builder.Services.AddSingleton<FcmTokenProvider>();
builder.Services.AddSingleton<IFcmAccessTokenSource>(sp => sp.GetRequiredService<FcmTokenProvider>());
// Push providers (spec 2026-11-06-notifications). Options are bound through
// the DI-resolved IConfiguration for the same reason as ModerationOptions:
// tests add Push:* settings via WebApplicationFactory after these top-level
// statements run. Each sender is a singleton (it caches its signing key and
// JWT) and is also exposed as IPushSender, which PushNotificationService
// dispatches on by Device.PushPlatform. Named HttpClients let tests swap the
// primary handler for a fake one per provider.
builder.Services.AddOptions<ApnsOptions>()
    .Configure<IConfiguration>((options, config) => config.GetSection(ApnsOptions.SectionName).Bind(options));
builder.Services.AddOptions<WebPushOptions>()
    .Configure<IConfiguration>((options, config) => config.GetSection(WebPushOptions.SectionName).Bind(options));
builder.Services.AddHttpClient(FcmSender.HttpClientName, c => c.Timeout = TimeSpan.FromSeconds(10));
builder.Services.AddHttpClient(WebPushSender.HttpClientName, c => c.Timeout = TimeSpan.FromSeconds(10));
// APNs is HTTP/2 only. Apple also asks providers to keep connections open
// rather than reconnect per push (it may treat churn as a DoS), hence the
// long handler lifetime instead of the factory's 2-minute default.
builder.Services.AddHttpClient(ApnsSender.HttpClientName, c =>
    {
        c.DefaultRequestVersion = HttpVersion.Version20;
        c.DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact;
        c.Timeout = TimeSpan.FromSeconds(10);
    })
    .SetHandlerLifetime(TimeSpan.FromMinutes(30));
builder.Services.AddSingleton<FcmSender>();
builder.Services.AddSingleton<ApnsSender>();
builder.Services.AddSingleton<WebPushSender>();
builder.Services.AddSingleton<IPushSender>(sp => sp.GetRequiredService<FcmSender>());
builder.Services.AddSingleton<IPushSender>(sp => sp.GetRequiredService<ApnsSender>());
builder.Services.AddSingleton<IPushSender>(sp => sp.GetRequiredService<WebPushSender>());
builder.Services.AddSingleton<PushNotificationService>();

// TURN credential provider — chosen by Turn:Provider:
//   "shared-secret" (default): HMAC credentials for self-hosted coturn/DeskShare.Turn
//   "cloudflare":              credentials minted by the Cloudflare TURN API
// Both are singletons: stateless, config read once, pooled HttpClient.
if (string.Equals(builder.Configuration["Turn:Provider"], "cloudflare", StringComparison.OrdinalIgnoreCase))
{
    // Bounded timeout so a Cloudflare outage cannot hang call setup indefinitely.
    builder.Services.AddHttpClient(CloudflareTurnCredentialService.HttpClientName,
        c => c.Timeout = TimeSpan.FromSeconds(10));
    builder.Services.AddSingleton<ITurnCredentialProvider, CloudflareTurnCredentialService>();
}
else
{
    builder.Services.AddSingleton<ITurnCredentialProvider, TurnCredentialService>();
}

// JwtService is a singleton — reads config once, generates/validates tokens.
// No DbContext dependency, no mutable state.
builder.Services.AddSingleton<JwtService>();

// MFA (N03a): TimeProvider is injected everywhere time-of-check matters so
// tests can control it; MfaEncryptionService/TotpService are singletons
// (config read once resp. no state beyond the injected clock).
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<MfaEncryptionService>();
builder.Services.AddSingleton<TotpService>();

// MessageCleanupService runs hourly to bulk-delete expired queued messages.
// Prevents unbounded storage growth from abandoned devices that never reconnect.
builder.Services.AddHostedService<MessageCleanupService>();

// Backup quota limits (K03) — see CallType.Api.Configuration.BackupLimitsOptions
// for defaults. BackupStorageService enforces them at reservation time;
// BackupCleanupService reclaims abandoned reservations and finishes interrupted deletes.
builder.Services.Configure<CallType.Api.Configuration.BackupLimitsOptions>(
    builder.Configuration.GetSection(CallType.Api.Configuration.BackupLimitsOptions.SectionName));
builder.Services.AddScoped<BackupStorageService>();
builder.Services.AddHostedService<BackupCleanupService>();

// Public channels — limits and retention, see ChannelsOptions for defaults.
// ChannelPostCleanupService hard-deletes posts (and their images) older than
// Channels:PostRetentionDays; it is the only place retention is enforced.
builder.Services.Configure<ChannelsOptions>(
    builder.Configuration.GetSection(ChannelsOptions.SectionName));
builder.Services.AddHostedService<ChannelPostCleanupService>();
// Scoped for the same reason as MessageQueueService: it uses the scoped AppDbContext.
builder.Services.AddScoped<ChannelService>();

// Channel moderation (operator web, /admin/*). Bound through the DI-resolved
// IConfiguration for the same reason as BusinessOptions below: tests set
// Moderation:OperatorAccountIds via WebApplicationFactory, which applies its
// configuration after these top-level statements run.
builder.Services.AddOptions<ModerationOptions>()
    .Configure<IConfiguration>((options, config) =>
        config.GetSection(ModerationOptions.SectionName).Bind(options));
builder.Services.AddScoped<ModerationService>();

// BlobServiceClient for Azure Blob Storage — used by backup endpoints to upload
// and download encrypted backup files. Registered as singleton because the client
// is thread-safe and maintains an internal connection pool.
builder.Services.AddSingleton(_ =>
    new BlobServiceClient(builder.Configuration.GetConnectionString("BlobStorage")));

// Business mode (organizations + audit archive, docs/superpowers/plans/2026-09-18-business-mode.md)
// is entirely optional: it is ON only when ConnectionStrings:Audit is
// configured; otherwise every business endpoint answers 503
// business_mode_disabled and the anonymous product works unchanged.
//
// The services below are registered UNCONDITIONALLY and the connection string
// is read lazily from IConfiguration at resolve time — not from
// builder.Configuration here. Two reasons, both found by the first real
// Testcontainers run:
//  1. Conditional registration made minimal-API parameter inference fail at
//     startup for handlers that take these services, taking the whole API down
//     in an anonymous-only deployment.
//  2. WebApplicationFactory applies test configuration AFTER this file's
//     top-level statements run, so a build-time read always saw "disabled".
// Nothing connects to the audit database unless a business endpoint is
// actually called with business mode enabled.
builder.Services.AddSingleton(sp => new BusinessModeOptions
{
    Enabled = !string.IsNullOrEmpty(sp.GetRequiredService<IConfiguration>().GetConnectionString("Audit"))
});
builder.Services.AddDbContext<AuditDbContext>((sp, options) =>
    options.UseNpgsql(
        sp.GetRequiredService<IConfiguration>().GetConnectionString("Audit")
        // Placeholder keeps DI resolvable when disabled; it is never opened
        // because every caller checks BusinessModeOptions.Enabled first.
        ?? "Host=business-mode-disabled"));

// Organization context (E01) + business groups (E02). IDeliveryDirectory is
// the seam CallType.Audit uses to look up Delivery data without ever
// referencing AppDbContext (KB3). BusinessGroupService is the real
// IEnrollmentRevokedHandler: revoking an enrollment removes the device from
// the organization's groups.
builder.Services.AddScoped<CallType.Audit.Application.IDeliveryDirectory, DeliveryDirectory>();
builder.Services.AddScoped<BusinessGroupService>();
builder.Services.AddScoped<IEnrollmentRevokedHandler>(sp => sp.GetRequiredService<BusinessGroupService>());
builder.Services.AddScoped<CallType.Audit.OrgManagement.OrganizationAppService>();

// W2-F: fail-closed on a dead auditor. IMemoryCache backs the 5 s
// per-organization liveness cache so the hot send path doesn't run the
// backlog query per message.
//
// Binds via the DI-resolved IConfiguration (AddOptions<T>().Configure<IConfiguration>)
// rather than builder.Configuration.GetSection(...) directly — same reason as
// BusinessModeOptions above: WebApplicationFactory applies test configuration
// overrides AFTER this file's top-level statements run, so a build-time read
// of builder.Configuration would capture a stale section that never sees a
// test's ["Business:..."] override.
builder.Services.AddMemoryCache();
builder.Services.AddOptions<BusinessOptions>()
    .Configure<IConfiguration>((options, config) =>
        config.GetSection(BusinessOptions.SectionName).Bind(options));
builder.Services.AddScoped<AuditorLivenessService>();
builder.Services.AddScoped<OrgCommunicationPolicy>();

// Emergency channel (E07): kits/drills/proof live in the Audit DB
// (EmergencyAppService); the Delivery-side emergency group is a separate
// service (EmergencyGroupService) per the KB3 database split.
builder.Services.AddScoped<CallType.Audit.Emergency.EmergencyAppService>();
builder.Services.AddScoped<EmergencyGroupService>();

// ReadinessService backs GET /health/ready — scoped because it depends on the
// scoped AppDbContext (same lifetime rule as MessageQueueService above).
builder.Services.AddScoped<ReadinessService>();

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
// Limits are configurable (default matches the previous hardcoded values) so
// docker-compose can raise the "auth" limit for local live E2E runs — those
// need more than 10 auth calls/minute — while production keeps the stricter
// default. See RateLimiting__AuthPermitLimit in docker-compose.yml.
var apiPermitLimit = builder.Configuration.GetValue<int?>("RateLimiting:ApiPermitLimit") ?? 100;
var authPermitLimit = builder.Configuration.GetValue<int?>("RateLimiting:AuthPermitLimit") ?? 10;
builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("api", context =>
    {
        var device = context.User.Identity?.IsAuthenticated == true
            ? context.User.FindFirstValue(ClaimTypes.NameIdentifier) ?? context.User.FindFirstValue("sub")
            : null;
        var key = device is null
            ? $"ip:{context.Connection.RemoteIpAddress?.ToString() ?? "unknown"}"
            : $"device:{device}";
        return RateLimitPartition.GetFixedWindowLimiter(key, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = apiPermitLimit, Window = TimeSpan.FromMinutes(1), QueueLimit = 0
        });
    });
    options.AddPolicy("auth", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = authPermitLimit, Window = TimeSpan.FromMinutes(1), QueueLimit = 0
        }));

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

        // Without this, the default inbound claim map silently renames
        // well-known short JWT claim names (e.g. "sub" -> ClaimTypes.NameIdentifier,
        // "amr" -> a long claims-schema URI) on the ClaimsPrincipal ASP.NET Core
        // builds from a validated token. Several call sites already worked around
        // the "sub" case by checking both names (see AccountEndpoints.CallerDeviceId,
        // MessengerHub.cs:325) — but N03b's MfaAuthHelper.RequireStepUp reads the
        // short "amr"/"mfa_acc"/"mfa_at" claims this JWT actually carries (see
        // JwtService.GenerateStepUpToken) and has no such workaround, so every
        // step-up check silently failed with mfa_required even for a fresh, valid
        // token. Disabling the mapping keeps claim names exactly as issued.
        options.MapInboundClaims = false;

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
            },

            // Token separation (moderation contract 4): an operator token
            // (scope=moderation, sub = ACCOUNT id) is valid only under /admin.
            // Everywhere else its sub would be read as a DEVICE id, so it is
            // rejected outright (401) instead of relying on every handler to
            // notice. The opposite direction (device token on /admin -> 403
            // operator_token_required) is ModerationEndpoints' group filter,
            // because it needs a JSON body with a code.
            OnTokenValidated = context =>
            {
                var isOperatorToken = context.Principal?.HasClaim(
                    JwtService.ScopeClaim, JwtService.ModerationScope) == true;
                if (isOperatorToken && !context.HttpContext.Request.Path.StartsWithSegments("/admin"))
                    context.Fail("Operator token is only valid on /admin.");
                return Task.CompletedTask;
            }
        };
    });

builder.Services.AddAuthorization();

// SignalR is the real-time transport for message relay, typing indicators,
// and WebRTC call signaling. Called explicitly for clarity even though the
// shared framework may include it.
builder.Services.AddSignalR(options => options.MaximumReceiveMessageSize = 1024 * 1024);

var app = builder.Build();

// Fail fast if Production is about to run with missing/default/known-dev
// config (K05). No-op outside Production, so local Development (docker-compose)
// is unaffected.
ProductionConfigurationValidator.Validate(app.Configuration, app.Environment);

// Middleware order matters:
// 1. CORS — must be before auth so preflight OPTIONS requests are handled
// 2. Authentication establishes the device identity used for API quotas.
// 3. Rate limiter and authorization.
if (IPAddress.TryParse(app.Configuration["Proxy:KnownProxy"], out _)) app.UseForwardedHeaders();
app.UseCors();

// The operator API does not exist until an operator is configured: every
// /admin route answers 404 (before authentication, so not even a 401 hints
// at it). Read per request so a config change needs no code path change.
app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/admin") &&
        context.RequestServices.GetRequiredService<Microsoft.Extensions.Options.IOptions<ModerationOptions>>()
            .Value.OperatorAccountIds.Count == 0)
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        return;
    }
    await next();
});

app.UseAuthentication();
app.UseRateLimiter();
app.UseAuthorization();

// Liveness (/health) and readiness (/health/ready) probes for orchestrators
// (k8s, Azure App Service) and integration tests. See HealthEndpoints.cs.
app.MapHealthEndpoints();

// RFC 9116 security.txt (N04) — 404 until Security:ContactUri is configured.
app.MapSecurityTxtEndpoints();

// Auth endpoints use the stricter "auth" rate limiter to slow down brute-force.
app.MapAuthEndpoints();

app.MapDeviceEndpoints();
app.MapPushEndpoints();
app.MapDeviceListEndpoints();
app.MapAccountEndpoints();
app.MapMfaEndpoints();
app.MapGroupEndpoints();
app.MapMuteEndpoints();
app.MapBackupEndpoints();
app.MapChannelEndpoints();
app.MapModerationEndpoints(); // operator web: /admin/* (channel moderation)
app.MapTurnCredentialEndpoints();
app.MapOrganizationEndpoints();
app.MapAuditArchiveEndpoints();
app.MapEmergencyEndpoints();
app.MapPrivacyEndpoints(); // N09: GDPR account/device deletion + export

// Map the SignalR hub at /hub. The hub is protected by [Authorize] — clients
// must pass access_token as a query parameter during the WebSocket upgrade.
app.MapHub<MessengerHub>("/hub");

if (app.Configuration.GetValue<bool>("Database:ApplyMigrationsOnStartup"))
{
    await using var scope = app.Services.CreateAsyncScope();
    await scope.ServiceProvider.GetRequiredService<AppDbContext>().Database.MigrateAsync();

    // The audit APP role may only INSERT/SELECT (KB3), so it must never run
    // DDL. Startup migration therefore uses a separate schema-owner connection
    // (ConnectionStrings:AuditMigrations). Without it the audit schema is left
    // to the operator (`dotnet ef database update --context AuditDbContext`)
    // rather than quietly granting the app role DDL rights.
    var auditMigrationsConnection = app.Configuration.GetConnectionString("AuditMigrations");
    var businessModeEnabled = app.Services.GetRequiredService<BusinessModeOptions>().Enabled;
    if (businessModeEnabled && !string.IsNullOrEmpty(auditMigrationsConnection))
    {
        var migrationOptions = new DbContextOptionsBuilder<AuditDbContext>()
            .UseNpgsql(auditMigrationsConnection).Options;
        await using var migrationContext = new AuditDbContext(migrationOptions);
        await migrationContext.Database.MigrateAsync();
    }
    else if (businessModeEnabled)
    {
        app.Logger.LogWarning(
            "Business mode is enabled but ConnectionStrings:AuditMigrations is not set; audit schema migrations were NOT applied at startup.");
    }
}

app.Run();

// ---------------------------------------------------------------------------
// Partial class declaration makes the compiler-generated Program type visible
// to the test project via InternalsVisibleTo, which is required by
// WebApplicationFactory<Program> to discover the entry point assembly.
// ---------------------------------------------------------------------------
public partial class Program { }
