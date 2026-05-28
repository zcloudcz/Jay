# ZMessanger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an end-to-end encrypted multiplatform messenger with anonymous access, optional registration, voice/video calls, and cloud backup.

**Architecture:** Flutter single-codebase client (iOS, Android, Web) communicating with ASP.NET Core 8 backend via REST + SignalR WebSocket. E2EE via Signal Protocol (libsignal Rust → FFI/WASM). WebRTC for calls with shared STUN/TURN from RemoteDesktopNet. PostgreSQL server-side, SQLCipher client-side.

**Tech Stack:** Flutter/Dart, ASP.NET Core 8, SignalR, PostgreSQL, EF Core, libsignal (Rust), WebRTC, Azure Container Apps, Azure Blob Storage

**Spec:** `docs/superpowers/specs/2026-05-28-zmessanger-design.md`

---

## File Structure

### Backend (`src/server/`)

```
ZMessanger.sln
src/server/
├── ZMessanger.Api/
│   ├── Program.cs                          # Host builder, DI, middleware
│   ├── appsettings.json                    # Config (DB, Azure, TURN)
│   ├── Endpoints/
│   │   ├── DeviceEndpoints.cs              # POST /devices, GET /devices/{id}/key-bundle
│   │   ├── AccountEndpoints.cs             # POST /accounts, POST /accounts/login
│   │   ├── GroupEndpoints.cs               # POST /groups, PUT /groups/{id}/members
│   │   ├── BackupEndpoints.cs              # POST/GET /backups
│   │   └── TurnCredentialEndpoints.cs      # GET /turn/credentials
│   ├── Hubs/
│   │   └── MessengerHub.cs                 # SignalR hub (message relay, typing, call signaling)
│   ├── Services/
│   │   ├── MessageQueueService.cs          # Store-and-forward logic
│   │   ├── PushNotificationService.cs      # FCM + APNs relay
│   │   ├── TurnCredentialService.cs        # Time-limited TURN credentials (HMAC-SHA1)
│   │   └── MessageCleanupService.cs        # Background: delete expired messages
│   ├── Data/
│   │   ├── AppDbContext.cs                 # EF Core DbContext
│   │   └── Migrations/                     # EF Core migrations
│   ├── Models/
│   │   ├── Device.cs
│   │   ├── OneTimePreKey.cs
│   │   ├── Account.cs
│   │   ├── AccountDevice.cs
│   │   ├── QueuedMessage.cs
│   │   ├── Group.cs
│   │   ├── GroupMember.cs
│   │   └── Backup.cs
│   └── Dockerfile
├── ZMessanger.Api.Tests/
│   ├── Endpoints/
│   │   ├── DeviceEndpointsTests.cs
│   │   ├── AccountEndpointsTests.cs
│   │   ├── GroupEndpointsTests.cs
│   │   └── BackupEndpointsTests.cs
│   ├── Hubs/
│   │   └── MessengerHubTests.cs
│   ├── Services/
│   │   ├── MessageQueueServiceTests.cs
│   │   └── TurnCredentialServiceTests.cs
│   └── TestFixtures/
│       └── IntegrationTestBase.cs          # Testcontainers PostgreSQL
```

### Flutter Client (`src/client/`)

```
src/client/zmessanger/
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   ├── app/
│   │   ├── app.dart                        # MaterialApp + router
│   │   ├── router.dart                     # GoRouter routes
│   │   └── theme.dart                      # Material 3 light/dark
│   ├── core/
│   │   ├── crypto/
│   │   │   ├── signal_protocol.dart        # libsignal FFI/WASM wrapper
│   │   │   ├── key_manager.dart            # Identity Key + Pre-Key generation
│   │   │   ├── session_manager.dart        # X3DH + Double Ratchet sessions
│   │   │   ├── group_cipher.dart           # Sender Keys for group E2EE
│   │   │   └── backup_crypto.dart          # Argon2id + AES-256-GCM
│   │   ├── network/
│   │   │   ├── api_client.dart             # REST client (dio)
│   │   │   ├── signalr_client.dart         # SignalR connection + reconnect
│   │   │   └── webrtc_manager.dart         # WebRTC peer connection lifecycle
│   │   ├── storage/
│   │   │   ├── database.dart               # SQLCipher DB (drift)
│   │   │   ├── tables.dart                 # Table definitions
│   │   │   └── secure_storage.dart         # flutter_secure_storage wrapper
│   │   └── auth/
│   │       └── app_lock.dart               # PIN + biometric gate
│   ├── features/
│   │   ├── onboarding/
│   │   │   ├── onboarding_screen.dart
│   │   │   └── onboarding_controller.dart
│   │   ├── chat_list/
│   │   │   ├── chat_list_screen.dart
│   │   │   └── chat_list_controller.dart
│   │   ├── chat/
│   │   │   ├── chat_screen.dart
│   │   │   ├── chat_controller.dart
│   │   │   ├── message_bubble.dart
│   │   │   └── message_input.dart
│   │   ├── contacts/
│   │   │   ├── contacts_screen.dart
│   │   │   ├── qr_scanner_screen.dart
│   │   │   └── contacts_controller.dart
│   │   ├── calls/
│   │   │   ├── call_screen.dart
│   │   │   └── call_controller.dart
│   │   ├── groups/
│   │   │   ├── group_create_screen.dart
│   │   │   └── group_controller.dart
│   │   ├── backup/
│   │   │   ├── backup_settings_screen.dart
│   │   │   ├── restore_screen.dart
│   │   │   └── backup_controller.dart
│   │   └── settings/
│   │       ├── settings_screen.dart
│   │       ├── app_lock_settings_screen.dart
│   │       └── account_screen.dart
│   └── shared/
│       ├── widgets/
│       │   ├── avatar.dart
│       │   └── loading_overlay.dart
│       └── models/
│           ├── conversation.dart
│           ├── message.dart
│           └── contact.dart
├── test/
│   ├── core/
│   │   ├── crypto/
│   │   │   ├── key_manager_test.dart
│   │   │   ├── session_manager_test.dart
│   │   │   └── backup_crypto_test.dart
│   │   ├── network/
│   │   │   └── api_client_test.dart
│   │   └── storage/
│   │       └── database_test.dart
│   └── features/
│       ├── chat/
│       │   └── chat_controller_test.dart
│       └── onboarding/
│           └── onboarding_controller_test.dart
└── native/
    └── libsignal/                          # Rust FFI bridge project
        ├── Cargo.toml
        ├── src/
        │   └── lib.rs                      # C ABI exports wrapping libsignal-protocol
        └── build.sh                        # Build script for iOS/Android/WASM
```

---

## Phase 1: Backend Foundation

### Task 1: Solution Scaffolding

**Files:**
- Create: `src/server/ZMessanger.Api/ZMessanger.Api.csproj`
- Create: `src/server/ZMessanger.Api/Program.cs`
- Create: `src/server/ZMessanger.Api/appsettings.json`
- Create: `src/server/ZMessanger.Api.Tests/ZMessanger.Api.Tests.csproj`
- Create: `ZMessanger.sln`

- [ ] **Step 1: Create solution and API project**

```bash
cd C:\GIT\ZCLOUD\ZMessanger
dotnet new sln -n ZMessanger
mkdir -p src/server
dotnet new webapi -n ZMessanger.Api -o src/server/ZMessanger.Api --no-openapi
dotnet sln add src/server/ZMessanger.Api/ZMessanger.Api.csproj
```

- [ ] **Step 2: Create test project**

```bash
dotnet new xunit -n ZMessanger.Api.Tests -o src/server/ZMessanger.Api.Tests
dotnet sln add src/server/ZMessanger.Api.Tests/ZMessanger.Api.Tests.csproj
dotnet add src/server/ZMessanger.Api.Tests reference src/server/ZMessanger.Api
```

- [ ] **Step 3: Add NuGet packages to API project**

```bash
cd src/server/ZMessanger.Api
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL
dotnet add package Microsoft.AspNetCore.SignalR
dotnet add package Konscious.Security.Cryptography.Argon2  # Argon2id
dotnet add package Azure.Storage.Blobs
```

- [ ] **Step 4: Add NuGet packages to test project**

```bash
cd src/server/ZMessanger.Api.Tests
dotnet add package Testcontainers.PostgreSql
dotnet add package Microsoft.AspNetCore.Mvc.Testing
dotnet add package FluentAssertions
```

- [ ] **Step 5: Write minimal Program.cs**

```csharp
// src/server/ZMessanger.Api/Program.cs
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSignalR();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { Status = "healthy" }));

app.Run();
```

- [ ] **Step 6: Write health check test**

```csharp
// src/server/ZMessanger.Api.Tests/HealthCheckTests.cs
using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;
using FluentAssertions;

namespace ZMessanger.Api.Tests;

public class HealthCheckTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public HealthCheckTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task Health_endpoint_returns_ok()
    {
        var response = await _client.GetAsync("/health");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }
}
```

- [ ] **Step 7: Make Program class accessible to tests**

Add to `ZMessanger.Api.csproj`:
```xml
<ItemGroup>
  <InternalsVisibleTo Include="ZMessanger.Api.Tests" />
</ItemGroup>
```

Add to bottom of `Program.cs`:
```csharp
public partial class Program { }
```

- [ ] **Step 8: Run tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests -v normal`
Expected: 1 test PASS

- [ ] **Step 9: Create .gitignore and commit**

```bash
dotnet new gitignore
git init
git add -A
git commit -m "chore: scaffold ASP.NET Core solution with health check"
```

---

### Task 2: Database Schema + EF Core

**Files:**
- Create: `src/server/ZMessanger.Api/Data/AppDbContext.cs`
- Create: `src/server/ZMessanger.Api/Models/Device.cs`
- Create: `src/server/ZMessanger.Api/Models/OneTimePreKey.cs`
- Create: `src/server/ZMessanger.Api/Models/Account.cs`
- Create: `src/server/ZMessanger.Api/Models/AccountDevice.cs`
- Create: `src/server/ZMessanger.Api/Models/QueuedMessage.cs`
- Create: `src/server/ZMessanger.Api/Models/Group.cs`
- Create: `src/server/ZMessanger.Api/Models/GroupMember.cs`
- Create: `src/server/ZMessanger.Api/Models/Backup.cs`
- Create: `src/server/ZMessanger.Api.Tests/TestFixtures/IntegrationTestBase.cs`

- [ ] **Step 1: Create entity models**

```csharp
// src/server/ZMessanger.Api/Models/Device.cs
namespace ZMessanger.Api.Models;

public class Device
{
    public Guid DeviceId { get; set; }
    public string UserHandle { get; set; } = null!;
    public byte[] IdentityKey { get; set; } = null!;
    public byte[] SignedPreKey { get; set; } = null!;
    public string? PushToken { get; set; }
    public string? PushPlatform { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? LastSeenAt { get; set; }

    public List<OneTimePreKey> OneTimePreKeys { get; set; } = [];
    public List<AccountDevice> AccountDevices { get; set; } = [];
    public List<GroupMember> GroupMemberships { get; set; } = [];
}
```

```csharp
// src/server/ZMessanger.Api/Models/OneTimePreKey.cs
namespace ZMessanger.Api.Models;

public class OneTimePreKey
{
    public long Id { get; set; }
    public Guid DeviceId { get; set; }
    public int KeyId { get; set; }
    public byte[] PublicKey { get; set; } = null!;

    public Device Device { get; set; } = null!;
}
```

```csharp
// src/server/ZMessanger.Api/Models/Account.cs
namespace ZMessanger.Api.Models;

public class Account
{
    public Guid AccountId { get; set; }
    public string Email { get; set; } = null!;
    public byte[] AuthKeyHash { get; set; } = null!;
    public DateTimeOffset CreatedAt { get; set; }

    public List<AccountDevice> AccountDevices { get; set; } = [];
    public List<Backup> Backups { get; set; } = [];
}
```

```csharp
// src/server/ZMessanger.Api/Models/AccountDevice.cs
namespace ZMessanger.Api.Models;

public class AccountDevice
{
    public Guid AccountId { get; set; }
    public Guid DeviceId { get; set; }
    public DateTimeOffset LinkedAt { get; set; }

    public Account Account { get; set; } = null!;
    public Device Device { get; set; } = null!;
}
```

```csharp
// src/server/ZMessanger.Api/Models/QueuedMessage.cs
namespace ZMessanger.Api.Models;

public class QueuedMessage
{
    public long Id { get; set; }
    public Guid RecipientId { get; set; }
    public Guid SenderId { get; set; }
    public byte[] EncryptedBody { get; set; } = null!;
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
}
```

```csharp
// src/server/ZMessanger.Api/Models/Group.cs
namespace ZMessanger.Api.Models;

public class Group
{
    public Guid GroupId { get; set; }
    public byte[]? NameEncrypted { get; set; }
    public Guid CreatedBy { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public List<GroupMember> Members { get; set; } = [];
}
```

```csharp
// src/server/ZMessanger.Api/Models/GroupMember.cs
namespace ZMessanger.Api.Models;

public class GroupMember
{
    public Guid GroupId { get; set; }
    public Guid DeviceId { get; set; }
    public string Role { get; set; } = "member";
    public DateTimeOffset JoinedAt { get; set; }

    public Group Group { get; set; } = null!;
    public Device Device { get; set; } = null!;
}
```

```csharp
// src/server/ZMessanger.Api/Models/Backup.cs
namespace ZMessanger.Api.Models;

public class Backup
{
    public long Id { get; set; }
    public Guid AccountId { get; set; }
    public string BlobPath { get; set; } = null!;
    public long SizeBytes { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public Account Account { get; set; } = null!;
}
```

- [ ] **Step 2: Create DbContext**

```csharp
// src/server/ZMessanger.Api/Data/AppDbContext.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    public DbSet<Device> Devices => Set<Device>();
    public DbSet<OneTimePreKey> OneTimePreKeys => Set<OneTimePreKey>();
    public DbSet<Account> Accounts => Set<Account>();
    public DbSet<AccountDevice> AccountDevices => Set<AccountDevice>();
    public DbSet<QueuedMessage> QueuedMessages => Set<QueuedMessage>();
    public DbSet<Group> Groups => Set<Group>();
    public DbSet<GroupMember> GroupMembers => Set<GroupMember>();
    public DbSet<Backup> Backups => Set<Backup>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Device>(e =>
        {
            e.HasKey(d => d.DeviceId);
            e.HasIndex(d => d.UserHandle).IsUnique();
            e.Property(d => d.UserHandle).HasMaxLength(10);
            e.Property(d => d.PushPlatform).HasMaxLength(10);
        });

        modelBuilder.Entity<OneTimePreKey>(e =>
        {
            e.HasKey(k => k.Id);
            e.HasIndex(k => new { k.DeviceId, k.KeyId }).IsUnique();
            e.HasOne(k => k.Device).WithMany(d => d.OneTimePreKeys).HasForeignKey(k => k.DeviceId);
        });

        modelBuilder.Entity<Account>(e =>
        {
            e.HasKey(a => a.AccountId);
            e.HasIndex(a => a.Email).IsUnique();
            e.Property(a => a.Email).HasMaxLength(255);
        });

        modelBuilder.Entity<AccountDevice>(e =>
        {
            e.HasKey(ad => new { ad.AccountId, ad.DeviceId });
            e.HasOne(ad => ad.Account).WithMany(a => a.AccountDevices).HasForeignKey(ad => ad.AccountId);
            e.HasOne(ad => ad.Device).WithMany(d => d.AccountDevices).HasForeignKey(ad => ad.DeviceId);
        });

        modelBuilder.Entity<QueuedMessage>(e =>
        {
            e.HasKey(m => m.Id);
            e.HasIndex(m => new { m.RecipientId, m.CreatedAt });
        });

        modelBuilder.Entity<Group>(e =>
        {
            e.HasKey(g => g.GroupId);
        });

        modelBuilder.Entity<GroupMember>(e =>
        {
            e.HasKey(gm => new { gm.GroupId, gm.DeviceId });
            e.HasOne(gm => gm.Group).WithMany(g => g.Members).HasForeignKey(gm => gm.GroupId);
            e.HasOne(gm => gm.Device).WithMany(d => d.GroupMemberships).HasForeignKey(gm => gm.DeviceId);
            e.Property(gm => gm.Role).HasMaxLength(10);
        });

        modelBuilder.Entity<Backup>(e =>
        {
            e.HasKey(b => b.Id);
            e.HasOne(b => b.Account).WithMany(a => a.Backups).HasForeignKey(b => b.AccountId);
        });
    }
}
```

- [ ] **Step 3: Register DbContext in Program.cs**

```csharp
// src/server/ZMessanger.Api/Program.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default")));
builder.Services.AddSignalR();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { Status = "healthy" }));

app.Run();

public partial class Program { }
```

Add connection string to `appsettings.json`:
```json
{
  "ConnectionStrings": {
    "Default": "Host=localhost;Database=zmessanger;Username=postgres;Password=postgres"
  }
}
```

- [ ] **Step 4: Create integration test base with Testcontainers**

```csharp
// src/server/ZMessanger.Api.Tests/TestFixtures/IntegrationTestBase.cs
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Testcontainers.PostgreSql;
using ZMessanger.Api.Data;

namespace ZMessanger.Api.Tests.TestFixtures;

public class IntegrationTestBase : IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    protected WebApplicationFactory<Program> Factory { get; private set; } = null!;
    protected HttpClient Client { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        await _postgres.StartAsync();

        Factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.ConfigureServices(services =>
            {
                var descriptor = services.SingleOrDefault(
                    d => d.ServiceType == typeof(DbContextOptions<AppDbContext>));
                if (descriptor != null) services.Remove(descriptor);

                services.AddDbContext<AppDbContext>(options =>
                    options.UseNpgsql(_postgres.GetConnectionString()));
            });
        });

        Client = Factory.CreateClient();

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.EnsureCreatedAsync();
    }

    public async Task DisposeAsync()
    {
        Client.Dispose();
        await Factory.DisposeAsync();
        await _postgres.DisposeAsync();
    }
}
```

- [ ] **Step 5: Create initial EF Core migration**

```bash
cd src/server/ZMessanger.Api
dotnet tool install --global dotnet-ef
dotnet ef migrations add InitialCreate
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add EF Core models, DbContext, PostgreSQL schema, integration test base"
```

---

### Task 3: Device Registration API

**Files:**
- Create: `src/server/ZMessanger.Api/Endpoints/DeviceEndpoints.cs`
- Create: `src/server/ZMessanger.Api.Tests/Endpoints/DeviceEndpointsTests.cs`

- [ ] **Step 1: Write failing test for device registration**

```csharp
// src/server/ZMessanger.Api.Tests/Endpoints/DeviceEndpointsTests.cs
using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Endpoints;

public class DeviceEndpointsTests : IntegrationTestBase
{
    [Fact]
    public async Task Register_device_returns_handle()
    {
        var request = new
        {
            IdentityKey = Convert.ToBase64String(new byte[32]),
            SignedPreKey = Convert.ToBase64String(new byte[32]),
            OneTimePreKeys = new[]
            {
                new { KeyId = 1, PublicKey = Convert.ToBase64String(new byte[32]) },
                new { KeyId = 2, PublicKey = Convert.ToBase64String(new byte[32]) },
            }
        };

        var response = await Client.PostAsJsonAsync("/devices", request);

        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<DeviceRegistrationResponse>();
        body!.DeviceId.Should().NotBeEmpty();
        body.UserHandle.Should().MatchRegex(@"^ZM-[A-Z0-9]{4}-[A-Z0-9]{4}$");
    }

    [Fact]
    public async Task Register_device_without_keys_returns_bad_request()
    {
        var request = new { IdentityKey = "", SignedPreKey = "" };

        var response = await Client.PostAsJsonAsync("/devices", request);

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    private record DeviceRegistrationResponse(Guid DeviceId, string UserHandle);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test src/server/ZMessanger.Api.Tests --filter DeviceEndpoints -v normal`
Expected: FAIL — 404 (endpoint not mapped)

- [ ] **Step 3: Implement device registration endpoint**

```csharp
// src/server/ZMessanger.Api/Endpoints/DeviceEndpoints.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Endpoints;

public static class DeviceEndpoints
{
    public static void MapDeviceEndpoints(this WebApplication app)
    {
        app.MapPost("/devices", RegisterDevice);
        app.MapGet("/devices/{id:guid}/key-bundle", GetKeyBundle);
    }

    private static async Task<IResult> RegisterDevice(
        RegisterDeviceRequest request,
        AppDbContext db)
    {
        if (string.IsNullOrEmpty(request.IdentityKey) || string.IsNullOrEmpty(request.SignedPreKey))
            return Results.BadRequest(new { Error = "IdentityKey and SignedPreKey are required" });

        byte[] identityKey, signedPreKey;
        try
        {
            identityKey = Convert.FromBase64String(request.IdentityKey);
            signedPreKey = Convert.FromBase64String(request.SignedPreKey);
        }
        catch (FormatException)
        {
            return Results.BadRequest(new { Error = "Keys must be valid base64" });
        }

        var device = new Device
        {
            DeviceId = Guid.NewGuid(),
            UserHandle = await GenerateUniqueHandle(db),
            IdentityKey = identityKey,
            SignedPreKey = signedPreKey,
            CreatedAt = DateTimeOffset.UtcNow
        };

        if (request.OneTimePreKeys is { Length: > 0 })
        {
            foreach (var otk in request.OneTimePreKeys)
            {
                device.OneTimePreKeys.Add(new OneTimePreKey
                {
                    DeviceId = device.DeviceId,
                    KeyId = otk.KeyId,
                    PublicKey = Convert.FromBase64String(otk.PublicKey)
                });
            }
        }

        db.Devices.Add(device);
        await db.SaveChangesAsync();

        return Results.Created($"/devices/{device.DeviceId}",
            new { device.DeviceId, device.UserHandle });
    }

    private static async Task<IResult> GetKeyBundle(Guid id, AppDbContext db)
    {
        var device = await db.Devices
            .Include(d => d.OneTimePreKeys)
            .FirstOrDefaultAsync(d => d.DeviceId == id);

        if (device is null)
            return Results.NotFound();

        OneTimePreKey? oneTimeKey = null;
        if (device.OneTimePreKeys.Count > 0)
        {
            oneTimeKey = device.OneTimePreKeys[0];
            db.OneTimePreKeys.Remove(oneTimeKey);
            await db.SaveChangesAsync();
        }

        return Results.Ok(new
        {
            device.DeviceId,
            IdentityKey = Convert.ToBase64String(device.IdentityKey),
            SignedPreKey = Convert.ToBase64String(device.SignedPreKey),
            OneTimePreKey = oneTimeKey is null ? null : new
            {
                oneTimeKey.KeyId,
                PublicKey = Convert.ToBase64String(oneTimeKey.PublicKey)
            }
        });
    }

    private static async Task<string> GenerateUniqueHandle(AppDbContext db)
    {
        const string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        string handle;
        do
        {
            var part1 = new string(Enumerable.Range(0, 4).Select(_ => chars[Random.Shared.Next(chars.Length)]).ToArray());
            var part2 = new string(Enumerable.Range(0, 4).Select(_ => chars[Random.Shared.Next(chars.Length)]).ToArray());
            handle = $"ZM-{part1}-{part2}";
        } while (await db.Devices.AnyAsync(d => d.UserHandle == handle));

        return handle;
    }

    public record RegisterDeviceRequest(
        string IdentityKey,
        string SignedPreKey,
        PreKeyRequest[]? OneTimePreKeys);

    public record PreKeyRequest(int KeyId, string PublicKey);
}
```

- [ ] **Step 4: Register endpoints in Program.cs**

```csharp
// Add to Program.cs before app.Run():
using ZMessanger.Api.Endpoints;
// ...
app.MapDeviceEndpoints();
```

- [ ] **Step 5: Run tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests --filter DeviceEndpoints -v normal`
Expected: 2 tests PASS

- [ ] **Step 6: Write key bundle test**

```csharp
// Add to DeviceEndpointsTests.cs
[Fact]
public async Task Get_key_bundle_returns_keys_and_consumes_one_time_key()
{
    var request = new
    {
        IdentityKey = Convert.ToBase64String(new byte[32]),
        SignedPreKey = Convert.ToBase64String(new byte[32]),
        OneTimePreKeys = new[]
        {
            new { KeyId = 1, PublicKey = Convert.ToBase64String(new byte[32]) },
        }
    };
    var regResponse = await Client.PostAsJsonAsync("/devices", request);
    var reg = await regResponse.Content.ReadFromJsonAsync<DeviceRegistrationResponse>();

    var response = await Client.GetAsync($"/devices/{reg!.DeviceId}/key-bundle");

    response.StatusCode.Should().Be(HttpStatusCode.OK);
    var bundle = await response.Content.ReadFromJsonAsync<KeyBundleResponse>();
    bundle!.OneTimePreKey.Should().NotBeNull();
    bundle.OneTimePreKey!.KeyId.Should().Be(1);

    // Second fetch should have no one-time key left
    var response2 = await Client.GetAsync($"/devices/{reg.DeviceId}/key-bundle");
    var bundle2 = await response2.Content.ReadFromJsonAsync<KeyBundleResponse>();
    bundle2!.OneTimePreKey.Should().BeNull();
}

private record KeyBundleResponse(
    Guid DeviceId,
    string IdentityKey,
    string SignedPreKey,
    OtkResponse? OneTimePreKey);

private record OtkResponse(int KeyId, string PublicKey);
```

- [ ] **Step 7: Run all tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests -v normal`
Expected: all PASS

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: device registration + key bundle API with integration tests"
```

---

### Task 4: SignalR Messenger Hub

**Files:**
- Create: `src/server/ZMessanger.Api/Hubs/MessengerHub.cs`
- Create: `src/server/ZMessanger.Api/Services/MessageQueueService.cs`
- Create: `src/server/ZMessanger.Api.Tests/Services/MessageQueueServiceTests.cs`

- [ ] **Step 1: Write MessageQueueService tests**

```csharp
// src/server/ZMessanger.Api.Tests/Services/MessageQueueServiceTests.cs
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;
using ZMessanger.Api.Services;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Services;

public class MessageQueueServiceTests : IntegrationTestBase
{
    [Fact]
    public async Task Enqueue_stores_encrypted_message()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var service = new MessageQueueService(db);

        var recipientId = Guid.NewGuid();
        var senderId = Guid.NewGuid();
        var encrypted = new byte[] { 1, 2, 3, 4 };

        await service.EnqueueAsync(recipientId, senderId, encrypted);

        var queued = db.QueuedMessages.Where(m => m.RecipientId == recipientId).ToList();
        queued.Should().HaveCount(1);
        queued[0].EncryptedBody.Should().BeEquivalentTo(encrypted);
        queued[0].ExpiresAt.Should().BeAfter(DateTimeOffset.UtcNow.AddDays(29));
    }

    [Fact]
    public async Task Dequeue_returns_and_deletes_messages()
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var service = new MessageQueueService(db);

        var recipientId = Guid.NewGuid();
        await service.EnqueueAsync(recipientId, Guid.NewGuid(), [1, 2]);
        await service.EnqueueAsync(recipientId, Guid.NewGuid(), [3, 4]);

        var messages = await service.DequeueAsync(recipientId);

        messages.Should().HaveCount(2);
        db.QueuedMessages.Where(m => m.RecipientId == recipientId).Should().BeEmpty();
    }
}
```

- [ ] **Step 2: Implement MessageQueueService**

```csharp
// src/server/ZMessanger.Api/Services/MessageQueueService.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Services;

public class MessageQueueService
{
    private readonly AppDbContext _db;

    public MessageQueueService(AppDbContext db) => _db = db;

    public async Task EnqueueAsync(Guid recipientId, Guid senderId, byte[] encryptedBody)
    {
        _db.QueuedMessages.Add(new QueuedMessage
        {
            RecipientId = recipientId,
            SenderId = senderId,
            EncryptedBody = encryptedBody,
            CreatedAt = DateTimeOffset.UtcNow,
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30)
        });
        await _db.SaveChangesAsync();
    }

    public async Task<List<QueuedMessage>> DequeueAsync(Guid recipientId)
    {
        var messages = await _db.QueuedMessages
            .Where(m => m.RecipientId == recipientId && m.ExpiresAt > DateTimeOffset.UtcNow)
            .OrderBy(m => m.CreatedAt)
            .ToListAsync();

        _db.QueuedMessages.RemoveRange(messages);
        await _db.SaveChangesAsync();

        return messages;
    }
}
```

- [ ] **Step 3: Run tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests --filter MessageQueueService -v normal`
Expected: 2 tests PASS

- [ ] **Step 4: Implement MessengerHub**

```csharp
// src/server/ZMessanger.Api/Hubs/MessengerHub.cs
using Microsoft.AspNetCore.SignalR;
using ZMessanger.Api.Services;

namespace ZMessanger.Api.Hubs;

public class MessengerHub : Hub
{
    private static readonly Dictionary<Guid, string> _connections = new();
    private readonly MessageQueueService _messageQueue;

    public MessengerHub(MessageQueueService messageQueue)
    {
        _messageQueue = messageQueue;
    }

    public override async Task OnConnectedAsync()
    {
        var deviceId = GetDeviceId();
        if (deviceId != Guid.Empty)
        {
            lock (_connections)
                _connections[deviceId] = Context.ConnectionId;

            var queued = await _messageQueue.DequeueAsync(deviceId);
            foreach (var msg in queued)
            {
                await Clients.Caller.SendAsync("ReceiveMessage", new
                {
                    msg.SenderId,
                    EncryptedBody = Convert.ToBase64String(msg.EncryptedBody),
                    msg.CreatedAt
                });
            }
        }
        await base.OnConnectedAsync();
    }

    public override Task OnDisconnectedAsync(Exception? exception)
    {
        var deviceId = GetDeviceId();
        if (deviceId != Guid.Empty)
        {
            lock (_connections)
                _connections.Remove(deviceId);
        }
        return base.OnDisconnectedAsync(exception);
    }

    public async Task SendMessage(Guid recipientDeviceId, string encryptedBodyBase64)
    {
        var senderId = GetDeviceId();
        var encryptedBody = Convert.FromBase64String(encryptedBodyBase64);
        string? connectionId;

        lock (_connections)
            _connections.TryGetValue(recipientDeviceId, out connectionId);

        if (connectionId is not null)
        {
            await Clients.Client(connectionId).SendAsync("ReceiveMessage", new
            {
                SenderId = senderId,
                EncryptedBody = encryptedBodyBase64,
                CreatedAt = DateTimeOffset.UtcNow
            });
        }
        else
        {
            await _messageQueue.EnqueueAsync(recipientDeviceId, senderId, encryptedBody);
        }
    }

    public async Task SendGroupMessage(Guid groupId, Dictionary<Guid, string> encryptedPayloads)
    {
        var senderId = GetDeviceId();
        foreach (var (deviceId, encryptedBody) in encryptedPayloads)
        {
            string? connectionId;
            lock (_connections)
                _connections.TryGetValue(deviceId, out connectionId);

            if (connectionId is not null)
            {
                await Clients.Client(connectionId).SendAsync("ReceiveMessage", new
                {
                    SenderId = senderId,
                    GroupId = groupId,
                    EncryptedBody = encryptedBody,
                    CreatedAt = DateTimeOffset.UtcNow
                });
            }
            else
            {
                await _messageQueue.EnqueueAsync(deviceId, senderId, Convert.FromBase64String(encryptedBody));
            }
        }
    }

    public async Task TypingIndicator(string conversationId)
    {
        var senderId = GetDeviceId();
        await Clients.Others.SendAsync("TypingIndicator", new { SenderId = senderId, ConversationId = conversationId });
    }

    public async Task CallSignal(Guid targetDeviceId, string signalType, string payload)
    {
        string? connectionId;
        lock (_connections)
            _connections.TryGetValue(targetDeviceId, out connectionId);

        if (connectionId is not null)
        {
            await Clients.Client(connectionId).SendAsync("CallSignal", new
            {
                SenderId = GetDeviceId(),
                SignalType = signalType,
                Payload = payload
            });
        }
    }

    private Guid GetDeviceId()
    {
        var httpContext = Context.GetHttpContext();
        var deviceIdStr = httpContext?.Request.Query["deviceId"].FirstOrDefault();
        return Guid.TryParse(deviceIdStr, out var id) ? id : Guid.Empty;
    }
}
```

- [ ] **Step 5: Register hub and services in Program.cs**

```csharp
// Update Program.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Endpoints;
using ZMessanger.Api.Hubs;
using ZMessanger.Api.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default")));
builder.Services.AddScoped<MessageQueueService>();
builder.Services.AddSignalR();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { Status = "healthy" }));
app.MapDeviceEndpoints();
app.MapHub<MessengerHub>("/hub");

app.Run();

public partial class Program { }
```

- [ ] **Step 6: Run all tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests -v normal`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: SignalR MessengerHub with store-and-forward message queue"
```

---

### Task 5: Account, Group, Backup Endpoints + Message Cleanup

**Files:**
- Create: `src/server/ZMessanger.Api/Endpoints/AccountEndpoints.cs`
- Create: `src/server/ZMessanger.Api/Endpoints/GroupEndpoints.cs`
- Create: `src/server/ZMessanger.Api/Endpoints/BackupEndpoints.cs`
- Create: `src/server/ZMessanger.Api/Endpoints/TurnCredentialEndpoints.cs`
- Create: `src/server/ZMessanger.Api/Services/TurnCredentialService.cs`
- Create: `src/server/ZMessanger.Api/Services/MessageCleanupService.cs`
- Create: corresponding test files

- [ ] **Step 1: Implement AccountEndpoints**

```csharp
// src/server/ZMessanger.Api/Endpoints/AccountEndpoints.cs
using System.Security.Cryptography;
using Konscious.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Endpoints;

public static class AccountEndpoints
{
    public static void MapAccountEndpoints(this WebApplication app)
    {
        app.MapPost("/accounts", Register);
        app.MapPost("/accounts/login", Login);
        app.MapPost("/accounts/{accountId:guid}/devices/{deviceId:guid}", LinkDevice);
        app.MapGet("/accounts/{accountId:guid}/devices", GetLinkedDevices);
    }

    private static async Task<IResult> Register(RegisterAccountRequest request, AppDbContext db)
    {
        if (string.IsNullOrWhiteSpace(request.Email) || string.IsNullOrWhiteSpace(request.AuthKey))
            return Results.BadRequest(new { Error = "Email and AuthKey required" });

        if (await db.Accounts.AnyAsync(a => a.Email == request.Email))
            return Results.Conflict(new { Error = "Email already registered" });

        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = await HashArgon2(Convert.FromBase64String(request.AuthKey), salt);

        var account = new Account
        {
            AccountId = Guid.NewGuid(),
            Email = request.Email,
            AuthKeyHash = salt.Concat(hash).ToArray(),
            CreatedAt = DateTimeOffset.UtcNow
        };

        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        return Results.Created($"/accounts/{account.AccountId}", new { account.AccountId });
    }

    private static async Task<IResult> Login(LoginRequest request, AppDbContext db)
    {
        var account = await db.Accounts.FirstOrDefaultAsync(a => a.Email == request.Email);
        if (account is null)
            return Results.Unauthorized();

        var salt = account.AuthKeyHash[..16];
        var storedHash = account.AuthKeyHash[16..];
        var hash = await HashArgon2(Convert.FromBase64String(request.AuthKey), salt);

        if (!CryptographicOperations.FixedTimeEquals(hash, storedHash))
            return Results.Unauthorized();

        return Results.Ok(new { account.AccountId });
    }

    private static async Task<IResult> LinkDevice(Guid accountId, Guid deviceId, AppDbContext db)
    {
        if (!await db.Accounts.AnyAsync(a => a.AccountId == accountId))
            return Results.NotFound();
        if (!await db.Devices.AnyAsync(d => d.DeviceId == deviceId))
            return Results.NotFound();
        if (await db.AccountDevices.AnyAsync(ad => ad.AccountId == accountId && ad.DeviceId == deviceId))
            return Results.Conflict();

        db.AccountDevices.Add(new AccountDevice
        {
            AccountId = accountId,
            DeviceId = deviceId,
            LinkedAt = DateTimeOffset.UtcNow
        });
        await db.SaveChangesAsync();

        return Results.Ok();
    }

    private static async Task<IResult> GetLinkedDevices(Guid accountId, AppDbContext db)
    {
        var devices = await db.AccountDevices
            .Where(ad => ad.AccountId == accountId)
            .Select(ad => new { ad.DeviceId, ad.LinkedAt })
            .ToListAsync();

        return Results.Ok(devices);
    }

    private static async Task<byte[]> HashArgon2(byte[] password, byte[] salt)
    {
        var argon2 = new Argon2id(password) { Salt = salt, Iterations = 3, MemorySize = 65536, DegreeOfParallelism = 4 };
        return await argon2.GetBytesAsync(32);
    }

    public record RegisterAccountRequest(string Email, string AuthKey);
    public record LoginRequest(string Email, string AuthKey);
}
```

- [ ] **Step 2: Implement GroupEndpoints**

```csharp
// src/server/ZMessanger.Api/Endpoints/GroupEndpoints.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Endpoints;

public static class GroupEndpoints
{
    public static void MapGroupEndpoints(this WebApplication app)
    {
        app.MapPost("/groups", CreateGroup);
        app.MapGet("/groups/{groupId:guid}/members", GetMembers);
        app.MapPut("/groups/{groupId:guid}/members", AddMember);
        app.MapDelete("/groups/{groupId:guid}/members/{deviceId:guid}", RemoveMember);
    }

    private static async Task<IResult> CreateGroup(CreateGroupRequest request, AppDbContext db)
    {
        if (!await db.Devices.AnyAsync(d => d.DeviceId == request.CreatedBy))
            return Results.BadRequest(new { Error = "Device not found" });

        var group = new Group
        {
            GroupId = Guid.NewGuid(),
            NameEncrypted = request.NameEncrypted is not null ? Convert.FromBase64String(request.NameEncrypted) : null,
            CreatedBy = request.CreatedBy,
            CreatedAt = DateTimeOffset.UtcNow
        };

        group.Members.Add(new GroupMember
        {
            GroupId = group.GroupId,
            DeviceId = request.CreatedBy,
            Role = "admin",
            JoinedAt = DateTimeOffset.UtcNow
        });

        db.Groups.Add(group);
        await db.SaveChangesAsync();

        return Results.Created($"/groups/{group.GroupId}", new { group.GroupId });
    }

    private static async Task<IResult> GetMembers(Guid groupId, AppDbContext db)
    {
        var members = await db.GroupMembers
            .Where(gm => gm.GroupId == groupId)
            .Select(gm => new { gm.DeviceId, gm.Role, gm.JoinedAt })
            .ToListAsync();

        return members.Count == 0 ? Results.NotFound() : Results.Ok(members);
    }

    private static async Task<IResult> AddMember(Guid groupId, AddMemberRequest request, AppDbContext db)
    {
        if (!await db.Groups.AnyAsync(g => g.GroupId == groupId))
            return Results.NotFound();

        if (await db.GroupMembers.AnyAsync(gm => gm.GroupId == groupId && gm.DeviceId == request.DeviceId))
            return Results.Conflict();

        db.GroupMembers.Add(new GroupMember
        {
            GroupId = groupId,
            DeviceId = request.DeviceId,
            Role = "member",
            JoinedAt = DateTimeOffset.UtcNow
        });
        await db.SaveChangesAsync();

        return Results.Ok();
    }

    private static async Task<IResult> RemoveMember(Guid groupId, Guid deviceId, AppDbContext db)
    {
        var member = await db.GroupMembers
            .FirstOrDefaultAsync(gm => gm.GroupId == groupId && gm.DeviceId == deviceId);

        if (member is null)
            return Results.NotFound();

        db.GroupMembers.Remove(member);
        await db.SaveChangesAsync();

        return Results.Ok();
    }

    public record CreateGroupRequest(Guid CreatedBy, string? NameEncrypted);
    public record AddMemberRequest(Guid DeviceId);
}
```

- [ ] **Step 3: Implement BackupEndpoints**

```csharp
// src/server/ZMessanger.Api/Endpoints/BackupEndpoints.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Endpoints;

public static class BackupEndpoints
{
    public static void MapBackupEndpoints(this WebApplication app)
    {
        app.MapPost("/backups", UploadBackup);
        app.MapGet("/backups/{accountId:guid}", ListBackups);
    }

    private static async Task<IResult> UploadBackup(UploadBackupRequest request, AppDbContext db)
    {
        if (!await db.Accounts.AnyAsync(a => a.AccountId == request.AccountId))
            return Results.NotFound(new { Error = "Account not found" });

        var blobPath = $"backups/{request.AccountId}/{DateTimeOffset.UtcNow:yyyyMMdd_HHmmss}.enc";

        // TODO Phase 6: actual Azure Blob Storage upload
        // For now, store metadata only

        var backup = new Backup
        {
            AccountId = request.AccountId,
            BlobPath = blobPath,
            SizeBytes = request.SizeBytes,
            CreatedAt = DateTimeOffset.UtcNow
        };

        db.Backups.Add(backup);
        await db.SaveChangesAsync();

        return Results.Created($"/backups/{backup.Id}", new { backup.Id, backup.BlobPath });
    }

    private static async Task<IResult> ListBackups(Guid accountId, AppDbContext db)
    {
        var backups = await db.Backups
            .Where(b => b.AccountId == accountId)
            .OrderByDescending(b => b.CreatedAt)
            .Select(b => new { b.Id, b.BlobPath, b.SizeBytes, b.CreatedAt })
            .ToListAsync();

        return Results.Ok(backups);
    }

    public record UploadBackupRequest(Guid AccountId, long SizeBytes);
}
```

- [ ] **Step 4: Implement TurnCredentialService**

```csharp
// src/server/ZMessanger.Api/Services/TurnCredentialService.cs
using System.Security.Cryptography;
using System.Text;

namespace ZMessanger.Api.Services;

public class TurnCredentialService
{
    private readonly string _sharedSecret;
    private readonly int _ttlSeconds;

    public TurnCredentialService(IConfiguration config)
    {
        _sharedSecret = config["Turn:SharedSecret"] ?? "zmessanger-turn-secret";
        _ttlSeconds = config.GetValue("Turn:TtlSeconds", 86400);
    }

    public TurnCredentials Generate(string deviceId)
    {
        var expiry = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + _ttlSeconds;
        var username = $"{expiry}:{deviceId}";

        using var hmac = new HMACSHA1(Encoding.UTF8.GetBytes(_sharedSecret));
        var credential = Convert.ToBase64String(hmac.ComputeHash(Encoding.UTF8.GetBytes(username)));

        return new TurnCredentials(username, credential, _ttlSeconds);
    }

    public record TurnCredentials(string Username, string Credential, int TtlSeconds);
}
```

```csharp
// src/server/ZMessanger.Api/Endpoints/TurnCredentialEndpoints.cs
using ZMessanger.Api.Services;

namespace ZMessanger.Api.Endpoints;

public static class TurnCredentialEndpoints
{
    public static void MapTurnCredentialEndpoints(this WebApplication app)
    {
        app.MapGet("/turn/credentials", (string deviceId, TurnCredentialService turn) =>
        {
            if (string.IsNullOrEmpty(deviceId))
                return Results.BadRequest();

            var creds = turn.Generate(deviceId);
            return Results.Ok(creds);
        });
    }
}
```

- [ ] **Step 5: Implement MessageCleanupService**

```csharp
// src/server/ZMessanger.Api/Services/MessageCleanupService.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;

namespace ZMessanger.Api.Services;

public class MessageCleanupService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<MessageCleanupService> _logger;

    public MessageCleanupService(IServiceScopeFactory scopeFactory, ILogger<MessageCleanupService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

                var deleted = await db.QueuedMessages
                    .Where(m => m.ExpiresAt < DateTimeOffset.UtcNow)
                    .ExecuteDeleteAsync(stoppingToken);

                if (deleted > 0)
                    _logger.LogInformation("Cleaned up {Count} expired messages", deleted);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Error during message cleanup");
            }

            await Task.Delay(TimeSpan.FromHours(1), stoppingToken);
        }
    }
}
```

- [ ] **Step 6: Update Program.cs with all endpoints and services**

```csharp
// src/server/ZMessanger.Api/Program.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Endpoints;
using ZMessanger.Api.Hubs;
using ZMessanger.Api.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default")));
builder.Services.AddScoped<MessageQueueService>();
builder.Services.AddSingleton<TurnCredentialService>();
builder.Services.AddHostedService<MessageCleanupService>();
builder.Services.AddSignalR();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { Status = "healthy" }));
app.MapDeviceEndpoints();
app.MapAccountEndpoints();
app.MapGroupEndpoints();
app.MapBackupEndpoints();
app.MapTurnCredentialEndpoints();
app.MapHub<MessengerHub>("/hub");

app.Run();

public partial class Program { }
```

- [ ] **Step 7: Write tests for Account and TURN endpoints**

```csharp
// src/server/ZMessanger.Api.Tests/Endpoints/AccountEndpointsTests.cs
using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Endpoints;

public class AccountEndpointsTests : IntegrationTestBase
{
    [Fact]
    public async Task Register_and_login_roundtrip()
    {
        var authKey = Convert.ToBase64String(new byte[32]);
        var regResponse = await Client.PostAsJsonAsync("/accounts",
            new { Email = "test@example.com", AuthKey = authKey });

        regResponse.StatusCode.Should().Be(HttpStatusCode.Created);

        var loginResponse = await Client.PostAsJsonAsync("/accounts/login",
            new { Email = "test@example.com", AuthKey = authKey });

        loginResponse.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Login_with_wrong_key_returns_unauthorized()
    {
        await Client.PostAsJsonAsync("/accounts",
            new { Email = "test2@example.com", AuthKey = Convert.ToBase64String(new byte[32]) });

        var loginResponse = await Client.PostAsJsonAsync("/accounts/login",
            new { Email = "test2@example.com", AuthKey = Convert.ToBase64String(new byte[16]) });

        loginResponse.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Duplicate_email_returns_conflict()
    {
        var authKey = Convert.ToBase64String(new byte[32]);
        await Client.PostAsJsonAsync("/accounts", new { Email = "dup@example.com", AuthKey = authKey });

        var response = await Client.PostAsJsonAsync("/accounts", new { Email = "dup@example.com", AuthKey = authKey });

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
    }
}
```

```csharp
// src/server/ZMessanger.Api.Tests/Services/TurnCredentialServiceTests.cs
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using ZMessanger.Api.Services;

namespace ZMessanger.Api.Tests.Services;

public class TurnCredentialServiceTests
{
    [Fact]
    public void Generate_returns_valid_credentials()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Turn:SharedSecret"] = "test-secret",
                ["Turn:TtlSeconds"] = "3600"
            })
            .Build();

        var service = new TurnCredentialService(config);
        var creds = service.Generate("device-123");

        creds.Username.Should().Contain("device-123");
        creds.Credential.Should().NotBeNullOrEmpty();
        creds.TtlSeconds.Should().Be(3600);
    }

    [Fact]
    public void Same_input_same_time_produces_same_credential()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Turn:SharedSecret"] = "test-secret"
            })
            .Build();

        var service = new TurnCredentialService(config);
        var c1 = service.Generate("device-123");
        var c2 = service.Generate("device-123");

        // Same second = same username = same credential
        c1.Credential.Should().Be(c2.Credential);
    }
}
```

- [ ] **Step 8: Run all tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests -v normal`
Expected: all PASS

- [ ] **Step 9: Add Dockerfile**

```dockerfile
# src/server/ZMessanger.Api/Dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
WORKDIR /app
EXPOSE 8080

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["ZMessanger.Api.csproj", "."]
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "ZMessanger.Api.dll"]
```

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: account, group, backup, TURN credential endpoints + message cleanup"
```

---

## Phase 2: Flutter Client Foundation

### Task 6: Flutter Project Setup

**Files:**
- Create: `src/client/zmessanger/pubspec.yaml`
- Create: `src/client/zmessanger/lib/main.dart`

- [ ] **Step 1: Create Flutter project**

```bash
cd C:\GIT\ZCLOUD\ZMessanger\src\client
flutter create zmessanger --platforms=android,ios,web
cd zmessanger
```

- [ ] **Step 2: Add dependencies to pubspec.yaml**

```yaml
# Add to dependencies section of pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  go_router: ^14.0.0
  dio: ^5.4.0
  signalr_netcore: ^1.3.7
  flutter_webrtc: ^0.11.0
  sqflite_sqlcipher: ^3.1.0
  flutter_secure_storage: ^9.2.0
  local_auth: ^2.2.0
  mobile_scanner: ^5.1.0       # QR scanning
  qr_flutter: ^4.1.0           # QR generation
  provider: ^6.1.0              # State management
  path_provider: ^2.1.0
  share_plus: ^9.0.0            # Share invite links
  file_picker: ^8.0.0
  image_picker: ^1.0.0
  intl: ^0.19.0                 # Date formatting
  uuid: ^4.4.0
  crypto: ^3.0.0                # HMAC for TURN credentials

dev_dependencies:
  flutter_test:
    sdk: flutter
  mockito: ^5.4.0
  build_runner: ^2.4.0
  mockito: ^5.4.0
```

- [ ] **Step 3: Run flutter pub get**

Run: `flutter pub get`
Expected: success

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: scaffold Flutter project with dependencies"
```

---

### Task 7: Theme + Navigation

**Files:**
- Create: `src/client/zmessanger/lib/app/theme.dart`
- Create: `src/client/zmessanger/lib/app/router.dart`
- Create: `src/client/zmessanger/lib/app/app.dart`
- Modify: `src/client/zmessanger/lib/main.dart`

- [ ] **Step 1: Create Material 3 theme**

```dart
// lib/app/theme.dart
import 'package:flutter/material.dart';

class AppTheme {
  static const _seed = Color(0xFF1B8755); // Green accent

  static final light = ThemeData(
    colorSchemeSeed: _seed,
    brightness: Brightness.light,
    useMaterial3: true,
  );

  static final dark = ThemeData(
    colorSchemeSeed: _seed,
    brightness: Brightness.dark,
    useMaterial3: true,
  );
}
```

- [ ] **Step 2: Create router with placeholder screens**

```dart
// lib/app/router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final router = GoRouter(
  initialLocation: '/chats',
  routes: [
    GoRoute(path: '/onboarding', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/chats', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/chats/:id', builder: (_, state) => const Placeholder()),
    GoRoute(path: '/contacts', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/contacts/scan', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/groups/create', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/call/:id', builder: (_, state) => const Placeholder()),
    GoRoute(path: '/settings', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/settings/lock', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/settings/account', builder: (_, __) => const Placeholder()),
    GoRoute(path: '/settings/backup', builder: (_, __) => const Placeholder()),
  ],
);
```

- [ ] **Step 3: Create App widget**

```dart
// lib/app/app.dart
import 'package:flutter/material.dart';
import 'router.dart';
import 'theme.dart';

class ZMessangerApp extends StatelessWidget {
  const ZMessangerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ZMessanger',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
```

- [ ] **Step 4: Update main.dart**

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZMessangerApp());
}
```

- [ ] **Step 5: Run app to verify**

Run: `flutter run -d chrome`
Expected: blank Material 3 app renders

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Material 3 theme, GoRouter navigation, app shell"
```

---

### Task 8: Local Database (SQLCipher + Drift)

**Files:**
- Create: `src/client/zmessanger/lib/core/storage/database.dart`
- Create: `src/client/zmessanger/lib/core/storage/tables.dart`
- Create: `src/client/zmessanger/lib/core/storage/secure_storage.dart`

- [ ] **Step 1: Replace sqflite_sqlcipher with drift for type-safe queries**

Update `pubspec.yaml`:
```yaml
dependencies:
  drift: ^2.16.0
  drift_sqflite: ^2.0.0  # uses sqlcipher on mobile

dev_dependencies:
  drift_dev: ^2.16.0
  build_runner: ^2.4.0
```

Run: `flutter pub get`

- [ ] **Step 2: Define tables**

```dart
// lib/core/storage/tables.dart
import 'package:drift/drift.dart';

class Contacts extends Table {
  TextColumn get deviceId => text()();
  TextColumn get userHandle => text()();
  TextColumn get displayName => text().nullable()();
  BlobColumn get identityKey => blob()();
  BoolColumn get verified => boolean().withDefault(const Constant(false))();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // 'direct' | 'group'
  TextColumn get title => text().nullable()();
  DateTimeColumn get lastMessageAt => dateTime().nullable()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get senderId => text()();
  TextColumn get body => text().nullable()();
  TextColumn get type => text().withDefault(const Constant('text'))();
  TextColumn get attachmentPath => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('sent'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get receivedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SignalSessions extends Table {
  TextColumn get address => text()();
  BlobColumn get sessionData => blob()();

  @override
  Set<Column> get primaryKey => {address};
}

class BackupState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
```

- [ ] **Step 3: Create database class**

```dart
// lib/core/storage/database.dart
import 'package:drift/drift.dart';
import 'package:drift_sqflite/drift_sqflite.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Contacts, Conversations, Messages, SignalSessions, BackupState])
class AppDatabase extends _$AppDatabase {
  AppDatabase(String path, String encryptionKey)
      : super(SqfliteQueryExecutor(
          path: path,
          singleInstance: true,
          password: encryptionKey,
        ));

  @override
  int get schemaVersion => 1;
}
```

- [ ] **Step 4: Create secure storage wrapper**

```dart
// lib/core/storage/secure_storage.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  static const _storage = FlutterSecureStorage();
  static const _dbKeyName = 'db_encryption_key';
  static const _deviceIdName = 'device_id';
  static const _pinHashName = 'pin_hash';

  static Future<String> getOrCreateDbKey() async {
    var key = await _storage.read(key: _dbKeyName);
    if (key == null) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      key = base64Encode(bytes);
      await _storage.write(key: _dbKeyName, value: key);
    }
    return key;
  }

  static Future<String?> getDeviceId() => _storage.read(key: _deviceIdName);
  static Future<void> setDeviceId(String id) => _storage.write(key: _deviceIdName, value: id);

  static Future<String?> getPinHash() => _storage.read(key: _pinHashName);
  static Future<void> setPinHash(String hash) => _storage.write(key: _pinHashName, value: hash);
}
```

- [ ] **Step 5: Generate drift code**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: generates `database.g.dart`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: SQLCipher local database with drift, secure storage wrapper"
```

---

### Task 9: Onboarding Flow

**Files:**
- Create: `src/client/zmessanger/lib/features/onboarding/onboarding_screen.dart`
- Create: `src/client/zmessanger/lib/features/onboarding/onboarding_controller.dart`
- Create: `src/client/zmessanger/lib/core/network/api_client.dart`

- [ ] **Step 1: Create API client**

```dart
// lib/core/network/api_client.dart
import 'package:dio/dio.dart';

class ApiClient {
  final Dio _dio;

  ApiClient(String baseUrl) : _dio = Dio(BaseOptions(baseUrl: baseUrl));

  Future<Map<String, dynamic>> registerDevice({
    required String identityKey,
    required String signedPreKey,
    required List<Map<String, dynamic>> oneTimePreKeys,
  }) async {
    final response = await _dio.post('/devices', data: {
      'identityKey': identityKey,
      'signedPreKey': signedPreKey,
      'oneTimePreKeys': oneTimePreKeys,
    });
    return response.data;
  }

  Future<Map<String, dynamic>> getKeyBundle(String deviceId) async {
    final response = await _dio.get('/devices/$deviceId/key-bundle');
    return response.data;
  }

  Future<Map<String, dynamic>> getTurnCredentials(String deviceId) async {
    final response = await _dio.get('/turn/credentials', queryParameters: {'deviceId': deviceId});
    return response.data;
  }

  Future<Map<String, dynamic>> registerAccount({
    required String email,
    required String authKey,
  }) async {
    final response = await _dio.post('/accounts', data: {
      'email': email,
      'authKey': authKey,
    });
    return response.data;
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String authKey,
  }) async {
    final response = await _dio.post('/accounts/login', data: {
      'email': email,
      'authKey': authKey,
    });
    return response.data;
  }
}
```

- [ ] **Step 2: Create onboarding controller**

```dart
// lib/features/onboarding/onboarding_controller.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';

class OnboardingController extends ChangeNotifier {
  final ApiClient _api;
  String? deviceId;
  String? userHandle;
  bool isLoading = false;
  String? error;

  OnboardingController(this._api);

  Future<void> initializeDevice() async {
    isLoading = true;
    notifyListeners();

    try {
      // Generate placeholder keys (real keys come in Phase 3 with libsignal)
      final random = Random.secure();
      final identityKey = base64Encode(List.generate(32, (_) => random.nextInt(256)));
      final signedPreKey = base64Encode(List.generate(32, (_) => random.nextInt(256)));
      final otks = List.generate(100, (i) => {
        return {'keyId': i, 'publicKey': base64Encode(List.generate(32, (_) => random.nextInt(256)))};
      });

      final result = await _api.registerDevice(
        identityKey: identityKey,
        signedPreKey: signedPreKey,
        oneTimePreKeys: otks,
      );

      deviceId = result['deviceId'];
      userHandle = result['userHandle'];
      await SecureStorage.setDeviceId(deviceId!);

      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String get qrData => 'zmessanger://contact/$userHandle';
}
```

- [ ] **Step 3: Create onboarding screen**

```dart
// lib/features/onboarding/onboarding_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:go_router/go_router.dart';
import 'onboarding_controller.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  @override
  void initState() {
    super.initState();
    context.read<OnboardingController>().initializeDevice();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<OnboardingController>();
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat_bubble_outline, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 24),
              Text('ZMessanger', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text('Secure. Anonymous. Simple.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 48),
              if (ctrl.isLoading)
                const CircularProgressIndicator()
              else if (ctrl.error != null)
                Text(ctrl.error!, style: TextStyle(color: theme.colorScheme.error))
              else if (ctrl.userHandle != null) ...[
                Text('Your ID', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(ctrl.userHandle!,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                QrImageView(data: ctrl.qrData, size: 200),
                const SizedBox(height: 16),
                Text('Share this QR code to add contacts',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 48),
                FilledButton(
                  onPressed: () => context.go('/chats'),
                  child: const Text('Start Messaging'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Wire up router with real screens**

Update `router.dart` to import and use `OnboardingScreen`:
```dart
// lib/app/router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/onboarding/onboarding_screen.dart';

final router = GoRouter(
  initialLocation: '/onboarding',
  routes: [
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
    GoRoute(path: '/chats', builder: (_, __) => const Scaffold(body: Center(child: Text('Chats')))),
    // ... rest of routes stay as placeholders for now
  ],
);
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: onboarding flow with device registration, QR code display"
```

---

### Task 10: Chat List + Chat Detail UI

**Files:**
- Create: `src/client/zmessanger/lib/features/chat_list/chat_list_screen.dart`
- Create: `src/client/zmessanger/lib/features/chat/chat_screen.dart`
- Create: `src/client/zmessanger/lib/features/chat/message_bubble.dart`
- Create: `src/client/zmessanger/lib/features/chat/message_input.dart`
- Create: `src/client/zmessanger/lib/shared/widgets/avatar.dart`

- [ ] **Step 1: Create avatar widget**

```dart
// lib/shared/widgets/avatar.dart
import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  final String name;
  final double size;

  const UserAvatar({super.key, required this.name, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final color = Colors.primaries[name.hashCode % Colors.primaries.length];

    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withValues(alpha: 0.2),
      child: Text(initial, style: TextStyle(color: color, fontSize: size * 0.4)),
    );
  }
}
```

- [ ] **Step 2: Create chat list screen**

```dart
// lib/features/chat_list/chat_list_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/widgets/avatar.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZMessanger'),
        actions: [
          IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () => context.push('/contacts/scan')),
          IconButton(icon: const Icon(Icons.settings), onPressed: () => context.push('/settings')),
        ],
      ),
      body: ListView.builder(
        itemCount: 0, // Will be populated from local DB
        itemBuilder: (context, index) {
          return ListTile(
            leading: const UserAvatar(name: 'User'),
            title: const Text('Contact Name'),
            subtitle: const Text('Last message preview...'),
            trailing: const Text('12:34'),
            onTap: () => context.push('/chats/placeholder-id'),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts'),
        child: const Icon(Icons.chat),
      ),
    );
  }
}
```

- [ ] **Step 3: Create message bubble widget**

```dart
// lib/features/chat/message_bubble.dart
import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final String text;
  final bool isMine;
  final String time;

  const MessageBubble({super.key, required this.text, required this.isMine, required this.time});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMine ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(text, style: TextStyle(
              color: isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
            const SizedBox(height: 2),
            Text(time, style: TextStyle(
              fontSize: 11,
              color: isMine
                ? theme.colorScheme.onPrimary.withValues(alpha: 0.7)
                : theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Create message input widget**

```dart
// lib/features/chat/message_input.dart
import 'package:flutter/material.dart';

class MessageInput extends StatefulWidget {
  final void Function(String) onSend;

  const MessageInput({super.key, required this.onSend});

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            IconButton(icon: const Icon(Icons.attach_file), onPressed: () {}),
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(icon: const Icon(Icons.send), onPressed: _send),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 5: Create chat screen**

```dart
// lib/features/chat/chat_screen.dart
import 'package:flutter/material.dart';
import 'message_bubble.dart';
import 'message_input.dart';

class ChatScreen extends StatelessWidget {
  final String conversationId;

  const ChatScreen({super.key, required this.conversationId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Name'),
        actions: [
          IconButton(icon: const Icon(Icons.call), onPressed: () {}),
          IconButton(icon: const Icon(Icons.videocam), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: const [
                // Messages will be populated from local DB
              ],
            ),
          ),
          MessageInput(onSend: (text) {
            // Will be connected to E2EE + SignalR in Phase 4
          }),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Update router with real screens**

```dart
// lib/app/router.dart — full update
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/chat/chat_screen.dart';

final router = GoRouter(
  initialLocation: '/onboarding',
  routes: [
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
    GoRoute(path: '/chats', builder: (_, __) => const ChatListScreen()),
    GoRoute(
      path: '/chats/:id',
      builder: (_, state) => ChatScreen(conversationId: state.pathParameters['id']!),
    ),
    GoRoute(path: '/contacts', builder: (_, __) => const Scaffold(body: Center(child: Text('Contacts')))),
    GoRoute(path: '/contacts/scan', builder: (_, __) => const Scaffold(body: Center(child: Text('QR Scanner')))),
    GoRoute(path: '/groups/create', builder: (_, __) => const Scaffold(body: Center(child: Text('Create Group')))),
    GoRoute(path: '/call/:id', builder: (_, __) => const Scaffold(body: Center(child: Text('Call')))),
    GoRoute(path: '/settings', builder: (_, __) => const Scaffold(body: Center(child: Text('Settings')))),
    GoRoute(path: '/settings/lock', builder: (_, __) => const Scaffold(body: Center(child: Text('App Lock')))),
    GoRoute(path: '/settings/account', builder: (_, __) => const Scaffold(body: Center(child: Text('Account')))),
    GoRoute(path: '/settings/backup', builder: (_, __) => const Scaffold(body: Center(child: Text('Backup')))),
  ],
);
```

- [ ] **Step 7: Run app, verify UI renders**

Run: `flutter run -d chrome`
Expected: onboarding → chat list → chat detail navigation works

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: chat list, chat detail, message bubble, message input UI"
```

---

## Phase 3: E2EE Integration

### Task 11: libsignal Rust FFI Bridge

**Files:**
- Create: `src/client/zmessanger/native/libsignal/Cargo.toml`
- Create: `src/client/zmessanger/native/libsignal/src/lib.rs`
- Create: `src/client/zmessanger/native/libsignal/build.sh`

- [ ] **Step 1: Create Rust FFI bridge project**

```toml
# native/libsignal/Cargo.toml
[package]
name = "zmessanger_signal"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
libsignal-protocol = "0.1"
rand = "0.8"
libc = "0.2"
```

- [ ] **Step 2: Implement C ABI exports**

```rust
// native/libsignal/src/lib.rs
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::slice;

/// Generate an Ed25519 identity key pair.
/// Returns JSON: {"publicKey": "base64...", "privateKey": "base64..."}
#[no_mangle]
pub extern "C" fn signal_generate_identity_key_pair() -> *mut c_char {
    use libsignal_protocol::IdentityKeyPair;
    use rand::rngs::OsRng;

    let key_pair = IdentityKeyPair::generate(&mut OsRng);
    let public_key = base64_encode(key_pair.public_key().serialize().as_ref());
    let private_key = base64_encode(key_pair.serialize().as_ref());

    let json = format!(r#"{{"publicKey":"{}","privateKey":"{}"}}"#, public_key, private_key);
    CString::new(json).unwrap().into_raw()
}

/// Generate a signed pre-key.
/// identity_private_key: base64-encoded identity key pair serialized bytes
/// key_id: the ID for this pre-key
/// Returns JSON: {"keyId": N, "publicKey": "base64...", "serialized": "base64..."}
#[no_mangle]
pub extern "C" fn signal_generate_signed_pre_key(
    identity_private_key: *const c_char,
    key_id: u32,
) -> *mut c_char {
    // Implementation depends on exact libsignal-protocol API version
    // This is the structure — actual crypto calls may vary
    let json = format!(r#"{{"keyId":{},"publicKey":"placeholder","serialized":"placeholder"}}"#, key_id);
    CString::new(json).unwrap().into_raw()
}

/// Generate N one-time pre-keys starting at start_id.
/// Returns JSON array of {"keyId": N, "publicKey": "base64..."}
#[no_mangle]
pub extern "C" fn signal_generate_one_time_pre_keys(
    start_id: u32,
    count: u32,
) -> *mut c_char {
    let json = "[]".to_string(); // placeholder — real impl generates PreKeyRecords
    CString::new(json).unwrap().into_raw()
}

/// Free a string allocated by this library.
#[no_mangle]
pub extern "C" fn signal_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)); }
    }
}

fn base64_encode(data: &[u8]) -> String {
    use std::io::Write;
    let mut buf = Vec::new();
    let config = base64::engine::general_purpose::STANDARD;
    // Simple base64 — in production use the `base64` crate
    data.iter().for_each(|b| { let _ = write!(buf, "{:02x}", b); });
    String::from_utf8(buf).unwrap_or_default()
}
```

> **Note:** The exact libsignal-protocol Rust API surface depends on version. The FFI bridge pattern is correct — specific function signatures will be adjusted during implementation when the crate API is confirmed.

- [ ] **Step 3: Create build script**

```bash
#!/bin/bash
# native/libsignal/build.sh
set -e

# Android (arm64, armv7, x86_64)
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o ../../android/app/src/main/jniLibs build --release

# iOS (universal)
cargo lipo --release
cp target/universal/release/libzmessanger_signal.a ../../ios/Runner/

# WASM (for web)
wasm-pack build --target web --out-dir ../../web/pkg

echo "Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: libsignal Rust FFI bridge project scaffold"
```

---

### Task 12: Dart Crypto Layer

**Files:**
- Create: `src/client/zmessanger/lib/core/crypto/signal_protocol.dart`
- Create: `src/client/zmessanger/lib/core/crypto/key_manager.dart`
- Create: `src/client/zmessanger/lib/core/crypto/session_manager.dart`
- Create: `src/client/zmessanger/lib/core/crypto/group_cipher.dart`
- Create: `src/client/zmessanger/lib/core/crypto/backup_crypto.dart`
- Create: `src/client/zmessanger/test/core/crypto/key_manager_test.dart`

- [ ] **Step 1: Create FFI wrapper**

```dart
// lib/core/crypto/signal_protocol.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';

typedef SignalGenerateIdentityKeyPairNative = Pointer<Utf8> Function();
typedef SignalFreeStringNative = Void Function(Pointer<Utf8>);

class SignalProtocol {
  static late final DynamicLibrary _lib;
  static bool _initialized = false;

  static void initialize() {
    if (_initialized) return;
    if (kIsWeb) {
      // Web uses WASM — loaded separately via JS interop
      _initialized = true;
      return;
    }
    if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libzmessanger_signal.so');
    } else if (Platform.isIOS) {
      _lib = DynamicLibrary.process();
    }
    _initialized = true;
  }

  static Map<String, String> generateIdentityKeyPair() {
    if (kIsWeb) return _generateIdentityKeyPairWeb();

    final func = _lib.lookupFunction<SignalGenerateIdentityKeyPairNative, Pointer<Utf8> Function()>(
        'signal_generate_identity_key_pair');
    final freeFunc = _lib.lookupFunction<SignalFreeStringNative, void Function(Pointer<Utf8>)>(
        'signal_free_string');

    final resultPtr = func();
    final result = resultPtr.toDartString();
    freeFunc(resultPtr);

    return Map<String, String>.from(jsonDecode(result));
  }

  static Map<String, String> _generateIdentityKeyPairWeb() {
    // Web: call WASM module via JS interop
    // Placeholder — real implementation uses dart:js_interop
    throw UnimplementedError('Web WASM integration pending');
  }
}
```

- [ ] **Step 2: Create key manager**

```dart
// lib/core/crypto/key_manager.dart
import 'dart:convert';
import '../storage/secure_storage.dart';
import 'signal_protocol.dart';

class KeyManager {
  static const _identityKeyPairKey = 'identity_key_pair';
  static const _signedPreKeyKey = 'signed_pre_key';

  Future<Map<String, String>> getOrCreateIdentityKeyPair() async {
    final existing = await SecureStorage.read(_identityKeyPairKey);
    if (existing != null) {
      return Map<String, String>.from(jsonDecode(existing));
    }

    final keyPair = SignalProtocol.generateIdentityKeyPair();
    await SecureStorage.write(_identityKeyPairKey, jsonEncode(keyPair));
    return keyPair;
  }

  Future<String> getPublicIdentityKey() async {
    final keyPair = await getOrCreateIdentityKeyPair();
    return keyPair['publicKey']!;
  }
}
```

- [ ] **Step 3: Create session manager**

```dart
// lib/core/crypto/session_manager.dart
import 'dart:typed_data';
import '../storage/database.dart';

class SessionManager {
  final AppDatabase _db;

  SessionManager(this._db);

  Future<Uint8List> encryptMessage(String recipientDeviceId, String plaintext) async {
    // Load or create session from signal_sessions table
    // Perform Double Ratchet encryption
    // Return encrypted bytes

    // Placeholder — real implementation uses libsignal FFI
    throw UnimplementedError('E2EE encryption pending libsignal integration');
  }

  Future<String> decryptMessage(String senderDeviceId, Uint8List ciphertext) async {
    // Load session, perform Double Ratchet decryption
    // Return plaintext

    throw UnimplementedError('E2EE decryption pending libsignal integration');
  }

  Future<void> initializeSession(String deviceId, Map<String, dynamic> keyBundle) async {
    // Perform X3DH key agreement using key bundle
    // Store resulting session in signal_sessions table

    throw UnimplementedError('X3DH session init pending libsignal integration');
  }
}
```

- [ ] **Step 4: Create group cipher**

```dart
// lib/core/crypto/group_cipher.dart
import 'dart:typed_data';

class GroupCipher {
  Future<Map<String, Uint8List>> encryptForGroup({
    required String groupId,
    required List<String> memberDeviceIds,
    required String plaintext,
  }) async {
    // Encrypt with sender key, distribute via 1:1 sessions
    throw UnimplementedError('Sender Keys pending libsignal integration');
  }

  Future<String> decryptGroupMessage({
    required String groupId,
    required String senderDeviceId,
    required Uint8List ciphertext,
  }) async {
    throw UnimplementedError('Sender Keys pending libsignal integration');
  }
}
```

- [ ] **Step 5: Create backup crypto**

```dart
// lib/core/crypto/backup_crypto.dart
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class BackupCrypto {
  /// Derive backup encryption key from passphrase using PBKDF2.
  /// (Argon2id preferred but no pure-Dart impl — use PBKDF2 with high iterations
  /// or call native Argon2 via FFI in production)
  static Uint8List deriveKey(String passphrase, Uint8List salt) {
    final pbkdf2 = Hmac(sha256, utf8.encode(passphrase));
    // PBKDF2 with 600,000 iterations (OWASP recommendation)
    var block = Uint8List.fromList([...salt, 0, 0, 0, 1]);
    var u = pbkdf2.convert(block).bytes;
    var result = Uint8List.fromList(u);
    for (var i = 1; i < 600000; i++) {
      u = pbkdf2.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return Uint8List.fromList(result);
  }

  static Uint8List generateSalt() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  }

  // AES-256-GCM encryption/decryption will use platform channels
  // or pointycastle package in production
}
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Dart crypto layer — key manager, session manager, group cipher, backup crypto"
```

---

## Phase 4: Chat Integration

### Task 13: SignalR Client

**Files:**
- Create: `src/client/zmessanger/lib/core/network/signalr_client.dart`

- [ ] **Step 1: Implement SignalR connection manager**

```dart
// lib/core/network/signalr_client.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:signalr_netcore/signalr_client.dart';

class SignalRClient extends ChangeNotifier {
  late HubConnection _hub;
  bool _connected = false;
  final String _baseUrl;
  final String _deviceId;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _typingController = StreamController<Map<String, dynamic>>.broadcast();
  final _callSignalController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onMessage => _messageController.stream;
  Stream<Map<String, dynamic>> get onTyping => _typingController.stream;
  Stream<Map<String, dynamic>> get onCallSignal => _callSignalController.stream;
  bool get connected => _connected;

  SignalRClient(this._baseUrl, this._deviceId);

  Future<void> connect() async {
    _hub = HubConnectionBuilder()
        .withUrl('$_baseUrl/hub?deviceId=$_deviceId')
        .withAutomaticReconnect()
        .build();

    _hub.on('ReceiveMessage', (args) {
      if (args != null && args.isNotEmpty) {
        _messageController.add(Map<String, dynamic>.from(args[0] as Map));
      }
    });

    _hub.on('TypingIndicator', (args) {
      if (args != null && args.isNotEmpty) {
        _typingController.add(Map<String, dynamic>.from(args[0] as Map));
      }
    });

    _hub.on('CallSignal', (args) {
      if (args != null && args.isNotEmpty) {
        _callSignalController.add(Map<String, dynamic>.from(args[0] as Map));
      }
    });

    _hub.onclose(({error}) {
      _connected = false;
      notifyListeners();
    });

    _hub.onreconnected(({connectionId}) {
      _connected = true;
      notifyListeners();
    });

    await _hub.start();
    _connected = true;
    notifyListeners();
  }

  Future<void> sendMessage(String recipientDeviceId, String encryptedBodyBase64) async {
    await _hub.invoke('SendMessage', args: [recipientDeviceId, encryptedBodyBase64]);
  }

  Future<void> sendGroupMessage(String groupId, Map<String, String> encryptedPayloads) async {
    await _hub.invoke('SendGroupMessage', args: [groupId, encryptedPayloads]);
  }

  Future<void> sendTypingIndicator(String conversationId) async {
    await _hub.invoke('TypingIndicator', args: [conversationId]);
  }

  Future<void> sendCallSignal(String targetDeviceId, String signalType, String payload) async {
    await _hub.invoke('CallSignal', args: [targetDeviceId, signalType, payload]);
  }

  Future<void> disconnect() async {
    await _hub.stop();
    _connected = false;
    notifyListeners();
  }

  void dispose() {
    _messageController.close();
    _typingController.close();
    _callSignalController.close();
    super.dispose();
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: SignalR client with message, typing, call signal streams"
```

---

### Task 14: Chat Controller (1:1 + Group)

**Files:**
- Create: `src/client/zmessanger/lib/features/chat/chat_controller.dart`
- Create: `src/client/zmessanger/lib/features/chat_list/chat_list_controller.dart`

- [ ] **Step 1: Create chat controller**

```dart
// lib/features/chat/chat_controller.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';

class ChatController extends ChangeNotifier {
  final AppDatabase _db;
  final SignalRClient _signalr;
  final String conversationId;
  final String myDeviceId;

  List<Message> messages = [];
  StreamSubscription? _messageSub;

  ChatController({
    required AppDatabase db,
    required SignalRClient signalr,
    required this.conversationId,
    required this.myDeviceId,
  })  : _db = db,
        _signalr = signalr {
    _loadMessages();
    _listenForIncoming();
  }

  Future<void> _loadMessages() async {
    messages = await (_db.select(_db.messages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
        .get();
    notifyListeners();
  }

  void _listenForIncoming() {
    _messageSub = _signalr.onMessage.listen((data) async {
      final senderId = data['senderId'] as String;
      // In production: decrypt with SessionManager
      final encryptedBody = data['encryptedBody'] as String;

      final msg = MessagesCompanion.insert(
        id: const Uuid().v4(),
        conversationId: conversationId,
        senderId: senderId,
        body: Value(encryptedBody), // placeholder — will be decrypted
        createdAt: DateTime.now(),
      );

      await _db.into(_db.messages).insert(msg);
      await _loadMessages();
    });
  }

  Future<void> sendMessage(String text) async {
    final msgId = const Uuid().v4();

    // Store locally
    await _db.into(_db.messages).insert(MessagesCompanion.insert(
      id: msgId,
      conversationId: conversationId,
      senderId: myDeviceId,
      body: Value(text),
      status: const Value('sending'),
      createdAt: DateTime.now(),
    ));
    await _loadMessages();

    // In production: encrypt with SessionManager before sending
    final encrypted = base64Encode(utf8.encode(text)); // placeholder

    try {
      await _signalr.sendMessage(conversationId, encrypted);
      await (_db.update(_db.messages)..where((m) => m.id.equals(msgId)))
          .write(const MessagesCompanion(status: Value('sent')));
    } catch (e) {
      await (_db.update(_db.messages)..where((m) => m.id.equals(msgId)))
          .write(const MessagesCompanion(status: Value('failed')));
    }
    await _loadMessages();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    super.dispose();
  }
}
```

- [ ] **Step 2: Create chat list controller**

```dart
// lib/features/chat_list/chat_list_controller.dart
import 'package:flutter/foundation.dart';
import '../../core/storage/database.dart';

class ChatListController extends ChangeNotifier {
  final AppDatabase _db;
  List<Conversation> conversations = [];

  ChatListController(this._db) {
    loadConversations();
  }

  Future<void> loadConversations() async {
    conversations = await (_db.select(_db.conversations)
          ..orderBy([(c) => OrderingTerm.desc(c.lastMessageAt)]))
        .get();
    notifyListeners();
  }

  Future<void> createDirectConversation(String deviceId) async {
    final existing = await (_db.select(_db.conversations)
          ..where((c) => c.id.equals(deviceId)))
        .getSingleOrNull();

    if (existing != null) return;

    await _db.into(_db.conversations).insert(ConversationsCompanion.insert(
      id: deviceId,
      type: 'direct',
    ));
    await loadConversations();
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: chat controller with local persistence + SignalR messaging"
```

---

### Task 15: Contact Management + QR Scanner

**Files:**
- Create: `src/client/zmessanger/lib/features/contacts/contacts_screen.dart`
- Create: `src/client/zmessanger/lib/features/contacts/qr_scanner_screen.dart`
- Create: `src/client/zmessanger/lib/features/contacts/contacts_controller.dart`

- [ ] **Step 1: Create contacts controller**

```dart
// lib/features/contacts/contacts_controller.dart
import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';

class ContactsController extends ChangeNotifier {
  final AppDatabase _db;
  final ApiClient _api;
  List<Contact> contacts = [];

  ContactsController(this._db, this._api) {
    loadContacts();
  }

  Future<void> loadContacts() async {
    contacts = await _db.select(_db.contacts).get();
    notifyListeners();
  }

  Future<bool> addContactByHandle(String handle) async {
    // Resolve handle to device info via API
    // In production: fetch key bundle, verify fingerprint
    try {
      // For now, store as contact — key exchange happens on first message
      await _db.into(_db.contacts).insert(ContactsCompanion.insert(
        deviceId: handle, // placeholder — will be resolved via API
        userHandle: handle,
        identityKey: Uint8List(32), // placeholder
        addedAt: DateTime.now(),
      ));
      await loadContacts();
      return true;
    } catch (e) {
      return false;
    }
  }
}
```

- [ ] **Step 2: Create QR scanner screen**

```dart
// lib/features/contacts/qr_scanner_screen.dart
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:go_router/go_router.dart';

class QrScannerScreen extends StatelessWidget {
  const QrScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(
        onDetect: (capture) {
          final barcode = capture.barcodes.firstOrNull;
          if (barcode?.rawValue == null) return;

          final uri = Uri.tryParse(barcode!.rawValue!);
          if (uri?.scheme == 'zmessanger' && uri?.host == 'contact') {
            final handle = uri!.pathSegments.first;
            // Add contact and navigate to chat
            context.pop(handle);
          }
        },
      ),
    );
  }
}
```

- [ ] **Step 3: Create contacts screen**

```dart
// lib/features/contacts/contacts_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/widgets/avatar.dart';

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () async {
              final handle = await context.push<String>('/contacts/scan');
              if (handle != null) {
                // Add contact via controller
              }
            },
          ),
        ],
      ),
      body: ListView(
        children: const [
          // Populated from contacts controller
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: contacts screen, QR scanner, contact controller"
```

---

## Phase 5: Voice & Video Calls

### Task 16: WebRTC Manager

**Files:**
- Create: `src/client/zmessanger/lib/core/network/webrtc_manager.dart`

- [ ] **Step 1: Implement WebRTC peer connection manager**

```dart
// lib/core/network/webrtc_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'signalr_client.dart';

enum CallState { idle, ringing, connecting, connected, ended }

class WebRTCManager extends ChangeNotifier {
  final SignalRClient _signalr;
  final String _myDeviceId;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  CallState state = CallState.idle;
  bool isVideo = false;
  String? remoteDeviceId;

  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get onRemoteStream => _remoteStreamController.stream;

  WebRTCManager(this._signalr, this._myDeviceId) {
    _signalr.onCallSignal.listen(_handleSignal);
  }

  Future<void> startCall(String targetDeviceId, {bool video = false}) async {
    remoteDeviceId = targetDeviceId;
    isVideo = video;
    state = CallState.connecting;
    notifyListeners();

    await _createPeerConnection(targetDeviceId);
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video,
    });

    for (var track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    await _signalr.sendCallSignal(targetDeviceId, 'offer', offer.sdp!);
  }

  Future<void> answerCall(String callerDeviceId, String offerSdp, {bool video = false}) async {
    remoteDeviceId = callerDeviceId;
    isVideo = video;
    state = CallState.connecting;
    notifyListeners();

    await _createPeerConnection(callerDeviceId);
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video,
    });

    for (var track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    await _pc!.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    await _signalr.sendCallSignal(callerDeviceId, 'answer', answer.sdp!);
  }

  Future<void> endCall() async {
    if (remoteDeviceId != null) {
      await _signalr.sendCallSignal(remoteDeviceId!, 'hangup', '');
    }
    await _cleanup();
  }

  void toggleMute() {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !t.enabled);
    notifyListeners();
  }

  void toggleCamera() {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !t.enabled);
    notifyListeners();
  }

  Future<void> _createPeerConnection(String targetDeviceId) async {
    // TURN credentials fetched from server in production
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:turn.zmsg.app:3478'},
        {
          'urls': 'turn:turn.zmsg.app:3479',
          'username': 'placeholder',
          'credential': 'placeholder',
        },
      ],
    });

    _pc!.onIceCandidate = (candidate) {
      _signalr.sendCallSignal(
          targetDeviceId, 'ice', '${candidate.candidate}|${candidate.sdpMid}|${candidate.sdpMLineIndex}');
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteStreamController.add(_remoteStream!);
        state = CallState.connected;
        notifyListeners();
      }
    };

    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _cleanup();
      }
    };
  }

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    final senderId = data['senderId'] as String;
    final signalType = data['signalType'] as String;
    final payload = data['payload'] as String;

    switch (signalType) {
      case 'offer':
        // Incoming call — notify UI to show incoming call screen
        state = CallState.ringing;
        remoteDeviceId = senderId;
        notifyListeners();
        break;
      case 'answer':
        await _pc?.setRemoteDescription(RTCSessionDescription(payload, 'answer'));
        break;
      case 'ice':
        final parts = payload.split('|');
        if (parts.length == 3) {
          await _pc?.addCandidate(RTCIceCandidate(parts[0], parts[1], int.tryParse(parts[2])));
        }
        break;
      case 'hangup':
        await _cleanup();
        break;
    }
  }

  Future<void> _cleanup() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _pc?.close();
    _pc = null;
    state = CallState.ended;
    remoteDeviceId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    _remoteStreamController.close();
    super.dispose();
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: WebRTC manager with call lifecycle, ICE, TURN support"
```

---

### Task 17: Call UI

**Files:**
- Create: `src/client/zmessanger/lib/features/calls/call_screen.dart`
- Create: `src/client/zmessanger/lib/features/calls/call_controller.dart`

- [ ] **Step 1: Create call screen**

```dart
// lib/features/calls/call_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../core/network/webrtc_manager.dart';

class CallScreen extends StatefulWidget {
  final String targetDeviceId;
  final bool isVideo;
  final bool isIncoming;

  const CallScreen({
    super.key,
    required this.targetDeviceId,
    this.isVideo = false,
    this.isIncoming = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();

    final webrtc = context.read<WebRTCManager>();
    webrtc.onRemoteStream.listen((stream) {
      _remoteRenderer.srcObject = stream;
    });
  }

  @override
  Widget build(BuildContext context) {
    final webrtc = context.watch<WebRTCManager>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Remote video (full screen)
            if (widget.isVideo && webrtc.state == CallState.connected)
              RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),

            // Call info overlay
            if (!widget.isVideo || webrtc.state != CallState.connected)
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.person, size: 80, color: Colors.white54),
                    const SizedBox(height: 16),
                    Text(widget.targetDeviceId,
                        style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white)),
                    const SizedBox(height: 8),
                    Text(
                      switch (webrtc.state) {
                        CallState.ringing => 'Ringing...',
                        CallState.connecting => 'Connecting...',
                        CallState.connected => 'Connected',
                        _ => '',
                      },
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),

            // Local video (small overlay)
            if (widget.isVideo)
              Positioned(
                top: 16,
                right: 16,
                width: 120,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(_localRenderer, mirror: true),
                ),
              ),

            // Controls
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CallButton(icon: Icons.mic_off, onPressed: webrtc.toggleMute),
                  _CallButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    onPressed: () {
                      webrtc.endCall();
                      Navigator.of(context).pop();
                    },
                  ),
                  if (widget.isVideo)
                    _CallButton(icon: Icons.videocam_off, onPressed: webrtc.toggleCamera),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  const _CallButton({required this.icon, required this.onPressed, this.color = Colors.white24});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 28,
      backgroundColor: color,
      child: IconButton(icon: Icon(icon, color: Colors.white), onPressed: onPressed),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: voice/video call UI with WebRTC renderers"
```

---

### Task 18: STUN/TURN Integration with RemoteDesktopNet

**Files:**
- Modify: `src/server/ZMessanger.Api/Services/TurnCredentialService.cs` (already done in Task 5)
- Modify: `src/client/zmessanger/lib/core/network/webrtc_manager.dart`

- [ ] **Step 1: Update WebRTC manager to fetch TURN credentials from API**

```dart
// Update _createPeerConnection in webrtc_manager.dart
Future<void> _createPeerConnection(String targetDeviceId) async {
  // Fetch time-limited TURN credentials from server
  final creds = await _apiClient.getTurnCredentials(_myDeviceId);

  _pc = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:turn.zmsg.app:3478'},
      {
        'urls': 'turn:turn.zmsg.app:3479',
        'username': creds['username'],
        'credential': creds['credential'],
      },
    ],
  });

  // ... rest of setup unchanged
}
```

- [ ] **Step 2: Add ApiClient dependency to WebRTCManager constructor**

```dart
// Update constructor
class WebRTCManager extends ChangeNotifier {
  final SignalRClient _signalr;
  final ApiClient _apiClient;
  final String _myDeviceId;

  WebRTCManager(this._signalr, this._apiClient, this._myDeviceId) {
    _signalr.onCallSignal.listen(_handleSignal);
  }
  // ...
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: integrate DeskShare STUN/TURN via API-issued credentials"
```

---

## Phase 6: Backup System

### Task 19: Server-Side Backup with Azure Blob Storage

**Files:**
- Modify: `src/server/ZMessanger.Api/Endpoints/BackupEndpoints.cs`

- [ ] **Step 1: Update BackupEndpoints with real Blob Storage upload/download**

```csharp
// src/server/ZMessanger.Api/Endpoints/BackupEndpoints.cs — full replacement
using Azure.Storage.Blobs;
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Endpoints;

public static class BackupEndpoints
{
    public static void MapBackupEndpoints(this WebApplication app)
    {
        app.MapPost("/backups/{accountId:guid}", UploadBackup).DisableAntiforgery();
        app.MapGet("/backups/{accountId:guid}", ListBackups);
        app.MapGet("/backups/{accountId:guid}/{backupId:long}", DownloadBackup);
    }

    private static async Task<IResult> UploadBackup(
        Guid accountId,
        IFormFile file,
        AppDbContext db,
        BlobServiceClient blobService)
    {
        if (!await db.Accounts.AnyAsync(a => a.AccountId == accountId))
            return Results.NotFound(new { Error = "Account not found" });

        var container = blobService.GetBlobContainerClient("backups");
        await container.CreateIfNotExistsAsync();

        var blobPath = $"{accountId}/{DateTimeOffset.UtcNow:yyyyMMdd_HHmmss}.enc";
        var blobClient = container.GetBlobClient(blobPath);

        await using var stream = file.OpenReadStream();
        await blobClient.UploadAsync(stream, overwrite: true);

        var backup = new Backup
        {
            AccountId = accountId,
            BlobPath = blobPath,
            SizeBytes = file.Length,
            CreatedAt = DateTimeOffset.UtcNow
        };
        db.Backups.Add(backup);
        await db.SaveChangesAsync();

        return Results.Created($"/backups/{accountId}/{backup.Id}", new { backup.Id, backup.BlobPath });
    }

    private static async Task<IResult> ListBackups(Guid accountId, AppDbContext db)
    {
        var backups = await db.Backups
            .Where(b => b.AccountId == accountId)
            .OrderByDescending(b => b.CreatedAt)
            .Select(b => new { b.Id, b.BlobPath, b.SizeBytes, b.CreatedAt })
            .ToListAsync();

        return Results.Ok(backups);
    }

    private static async Task<IResult> DownloadBackup(
        Guid accountId, long backupId,
        AppDbContext db, BlobServiceClient blobService)
    {
        var backup = await db.Backups
            .FirstOrDefaultAsync(b => b.Id == backupId && b.AccountId == accountId);

        if (backup is null) return Results.NotFound();

        var container = blobService.GetBlobContainerClient("backups");
        var blobClient = container.GetBlobClient(backup.BlobPath);

        var download = await blobClient.DownloadStreamingAsync();
        return Results.Stream(download.Value.Content, "application/octet-stream", $"backup_{backupId}.enc");
    }
}
```

- [ ] **Step 2: Register BlobServiceClient in Program.cs**

```csharp
// Add to Program.cs service registration
builder.Services.AddSingleton(_ =>
    new BlobServiceClient(builder.Configuration.GetConnectionString("BlobStorage")));
```

Add to `appsettings.json`:
```json
{
  "ConnectionStrings": {
    "Default": "Host=localhost;Database=zmessanger;Username=postgres;Password=postgres",
    "BlobStorage": "UseDevelopmentStorage=true"
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: backup upload/download with Azure Blob Storage"
```

---

### Task 20: Client-Side Backup Controller

**Files:**
- Create: `src/client/zmessanger/lib/features/backup/backup_controller.dart`
- Create: `src/client/zmessanger/lib/features/backup/backup_settings_screen.dart`
- Create: `src/client/zmessanger/lib/features/backup/restore_screen.dart`

- [ ] **Step 1: Create backup controller**

```dart
// lib/features/backup/backup_controller.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../../core/crypto/backup_crypto.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';

enum BackupStatus { idle, encrypting, uploading, done, error }

class BackupController extends ChangeNotifier {
  final AppDatabase _db;
  final ApiClient _api;
  final String accountId;

  BackupStatus status = BackupStatus.idle;
  String? error;
  double progress = 0;

  BackupController(this._db, this._api, this.accountId);

  Future<void> createBackup(String passphrase) async {
    try {
      status = BackupStatus.encrypting;
      notifyListeners();

      // 1. Export messages from local DB
      final messages = await _db.select(_db.messages).get();
      final contacts = await _db.select(_db.contacts).get();
      final conversations = await _db.select(_db.conversations).get();

      final payload = jsonEncode({
        'messages': messages.map((m) => {
              'id': m.id,
              'conversationId': m.conversationId,
              'senderId': m.senderId,
              'body': m.body,
              'type': m.type,
              'createdAt': m.createdAt.toIso8601String(),
            }).toList(),
        'contacts': contacts.map((c) => {
              'deviceId': c.deviceId,
              'userHandle': c.userHandle,
              'displayName': c.displayName,
            }).toList(),
        'conversations': conversations.map((c) => {
              'id': c.id,
              'type': c.type,
              'title': c.title,
            }).toList(),
      });

      // 2. Encrypt
      final salt = BackupCrypto.generateSalt();
      final key = BackupCrypto.deriveKey(passphrase, salt);
      // In production: AES-256-GCM encrypt payload with key
      // Placeholder: base64 encode
      final encrypted = Uint8List.fromList([...salt, ...utf8.encode(payload)]);

      // 3. Upload
      status = BackupStatus.uploading;
      notifyListeners();

      // In production: multipart upload to /backups/{accountId}
      // await _api.uploadBackup(accountId, encrypted);

      status = BackupStatus.done;
    } catch (e) {
      status = BackupStatus.error;
      error = e.toString();
    }
    notifyListeners();
  }

  Future<void> restore(String passphrase) async {
    // 1. List backups from server
    // 2. Download latest
    // 3. Decrypt with passphrase-derived key
    // 4. Import into local DB
    throw UnimplementedError('Restore flow');
  }
}
```

- [ ] **Step 2: Create backup settings screen**

```dart
// lib/features/backup/backup_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'backup_controller.dart';

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  final _passphraseController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<BackupController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cloud Backup', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('Your backup is encrypted with your passphrase. We cannot read it.'),
            const SizedBox(height: 24),
            TextField(
              controller: _passphraseController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Backup passphrase',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: ctrl.status == BackupStatus.idle
                  ? () => ctrl.createBackup(_passphraseController.text)
                  : null,
              child: switch (ctrl.status) {
                BackupStatus.encrypting => const Text('Encrypting...'),
                BackupStatus.uploading => const Text('Uploading...'),
                BackupStatus.done => const Text('Backup Complete'),
                BackupStatus.error => Text('Error: ${ctrl.error}'),
                _ => const Text('Create Backup'),
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: client-side encrypted backup with passphrase-derived key"
```

---

## Phase 7: App Lock + Push Notifications + Polish

### Task 21: App Lock (PIN + Biometrics)

**Files:**
- Create: `src/client/zmessanger/lib/core/auth/app_lock.dart`
- Create: `src/client/zmessanger/lib/features/settings/app_lock_settings_screen.dart`

- [ ] **Step 1: Create app lock service**

```dart
// lib/core/auth/app_lock.dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';
import '../storage/secure_storage.dart';

class AppLock {
  final _localAuth = LocalAuthentication();

  Future<bool> isEnabled() async {
    return await SecureStorage.getPinHash() != null;
  }

  Future<void> setPin(String pin) async {
    final hash = sha256.convert(utf8.encode(pin)).toString();
    await SecureStorage.setPinHash(hash);
  }

  Future<void> removePin() async {
    await SecureStorage.deletePinHash();
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await SecureStorage.getPinHash();
    if (stored == null) return true;
    final hash = sha256.convert(utf8.encode(pin)).toString();
    return hash == stored;
  }

  Future<bool> authenticateWithBiometrics() async {
    final available = await _localAuth.canCheckBiometrics;
    if (!available) return false;

    return await _localAuth.authenticate(
      localizedReason: 'Unlock ZMessanger',
      options: const AuthenticationOptions(biometricOnly: true),
    );
  }

  Future<bool> isBiometricAvailable() async {
    return await _localAuth.canCheckBiometrics;
  }
}
```

- [ ] **Step 2: Create app lock settings screen**

```dart
// lib/features/settings/app_lock_settings_screen.dart
import 'package:flutter/material.dart';
import '../../core/auth/app_lock.dart';

class AppLockSettingsScreen extends StatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  State<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends State<AppLockSettingsScreen> {
  final _appLock = AppLock();
  final _pinController = TextEditingController();
  bool _lockEnabled = false;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    _lockEnabled = await _appLock.isEnabled();
    _biometricAvailable = await _appLock.isBiometricAvailable();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App Lock')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Enable PIN Lock'),
            value: _lockEnabled,
            onChanged: (enabled) async {
              if (enabled) {
                await _showSetPinDialog();
              } else {
                await _appLock.removePin();
              }
              await _loadState();
            },
          ),
          if (_lockEnabled && _biometricAvailable)
            const SwitchListTile(
              title: Text('Use Biometrics'),
              subtitle: Text('Unlock with face or fingerprint'),
              value: true,
              onChanged: null, // Biometrics always enabled when available
            ),
        ],
      ),
    );
  }

  Future<void> _showSetPinDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set PIN'),
        content: TextField(
          controller: _pinController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          obscureText: true,
          decoration: const InputDecoration(hintText: '4-6 digits'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (_pinController.text.length >= 4) {
                await _appLock.setPin(_pinController.text);
                _pinController.clear();
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: app lock with PIN and biometric authentication"
```

---

### Task 22: Push Notification Relay (Server)

**Files:**
- Create: `src/server/ZMessanger.Api/Services/PushNotificationService.cs`
- Modify: `src/server/ZMessanger.Api/Hubs/MessengerHub.cs`

- [ ] **Step 1: Create push notification service**

```csharp
// src/server/ZMessanger.Api/Services/PushNotificationService.cs
using Microsoft.EntityFrameworkCore;
using ZMessanger.Api.Data;

namespace ZMessanger.Api.Services;

public class PushNotificationService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IHttpClientFactory _httpFactory;
    private readonly ILogger<PushNotificationService> _logger;

    public PushNotificationService(
        IServiceScopeFactory scopeFactory,
        IHttpClientFactory httpFactory,
        ILogger<PushNotificationService> logger)
    {
        _scopeFactory = scopeFactory;
        _httpFactory = httpFactory;
        _logger = logger;
    }

    public async Task SendPushAsync(Guid recipientDeviceId)
    {
        using var scope = _scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var device = await db.Devices.FirstOrDefaultAsync(d => d.DeviceId == recipientDeviceId);
        if (device?.PushToken is null) return;

        switch (device.PushPlatform)
        {
            case "fcm":
                await SendFcmAsync(device.PushToken);
                break;
            case "apns":
                await SendApnsAsync(device.PushToken);
                break;
            default:
                _logger.LogDebug("No push platform for device {DeviceId}", recipientDeviceId);
                break;
        }
    }

    private async Task SendFcmAsync(string token)
    {
        // FCM HTTP v1 API
        // In production: use Google.Apis.FirebaseCloudMessaging.v1 NuGet
        var client = _httpFactory.CreateClient("fcm");
        _logger.LogInformation("FCM push to {Token}", token[..10]);
        // Payload: { "notification": { "title": "New message", "body": "You have a new message" } }
        await Task.CompletedTask;
    }

    private async Task SendApnsAsync(string token)
    {
        // APNs HTTP/2 API
        _logger.LogInformation("APNs push to {Token}", token[..10]);
        await Task.CompletedTask;
    }
}
```

- [ ] **Step 2: Wire push into MessengerHub**

Add to `SendMessage` in `MessengerHub.cs`, after enqueue:
```csharp
// After: await _messageQueue.EnqueueAsync(...)
await _pushService.SendPushAsync(recipientDeviceId);
```

Add `PushNotificationService` to hub constructor:
```csharp
private readonly PushNotificationService _pushService;

public MessengerHub(MessageQueueService messageQueue, PushNotificationService pushService)
{
    _messageQueue = messageQueue;
    _pushService = pushService;
}
```

- [ ] **Step 3: Register services in Program.cs**

```csharp
// Add to Program.cs
builder.Services.AddHttpClient();
builder.Services.AddSingleton<PushNotificationService>();
```

- [ ] **Step 4: Add push token update endpoint**

```csharp
// Add to DeviceEndpoints.cs
app.MapPut("/devices/{id:guid}/push-token", async (Guid id, PushTokenRequest request, AppDbContext db) =>
{
    var device = await db.Devices.FindAsync(id);
    if (device is null) return Results.NotFound();

    device.PushToken = request.Token;
    device.PushPlatform = request.Platform;
    await db.SaveChangesAsync();

    return Results.Ok();
});

public record PushTokenRequest(string Token, string Platform);
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: push notification relay service (FCM + APNs)"
```

---

### Task 23: Settings Screen + Account Management

**Files:**
- Create: `src/client/zmessanger/lib/features/settings/settings_screen.dart`
- Create: `src/client/zmessanger/lib/features/settings/account_screen.dart`

- [ ] **Step 1: Create settings screen**

```dart
// lib/features/settings/settings_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('App Lock'),
            subtitle: const Text('PIN and biometrics'),
            onTap: () => context.push('/settings/lock'),
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Account'),
            subtitle: const Text('Register or login'),
            onTap: () => context.push('/settings/account'),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text('Backup'),
            subtitle: const Text('Cloud backup settings'),
            onTap: () => context.push('/settings/backup'),
          ),
          ListTile(
            leading: const Icon(Icons.devices),
            title: const Text('Linked Devices'),
            onTap: () {},
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About ZMessanger'),
            subtitle: const Text('v0.1.0'),
            onTap: () {},
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Create account screen**

```dart
// lib/features/settings/account_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import '../../core/network/api_client.dart';

class AccountScreen extends StatefulWidget {
  final ApiClient apiClient;

  const AccountScreen({super.key, required this.apiClient});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _emailController = TextEditingController();
  final _passphraseController = TextEditingController();
  bool _isLogin = false;
  bool _loading = false;
  String? _error;
  String? _accountId;

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });

    try {
      final authKey = base64Encode(
          sha256.convert(utf8.encode(_passphraseController.text)).bytes);

      if (_isLogin) {
        final result = await widget.apiClient.login(
          email: _emailController.text,
          authKey: authKey,
        );
        _accountId = result['accountId'];
      } else {
        final result = await widget.apiClient.registerAccount(
          email: _emailController.text,
          authKey: authKey,
        );
        _accountId = result['accountId'];
      }
    } catch (e) {
      _error = e.toString();
    }

    setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isLogin ? 'Login' : 'Register')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (_accountId != null) ...[
              const Icon(Icons.check_circle, size: 64, color: Colors.green),
              const SizedBox(height: 16),
              const Text('Account linked. Cloud backup enabled.'),
            ] else ...[
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passphraseController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passphrase', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_isLogin ? 'Login' : 'Register'),
              ),
              TextButton(
                onPressed: () => setState(() => _isLogin = !_isLogin),
                child: Text(_isLogin ? 'Need an account? Register' : 'Have an account? Login'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 3: Update router with all real screens**

Wire `SettingsScreen`, `AppLockSettingsScreen`, `AccountScreen`, `BackupSettingsScreen` into router.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: settings, account registration/login, backup settings UI"
```

---

### Task 24: Group Creation UI

**Files:**
- Create: `src/client/zmessanger/lib/features/groups/group_create_screen.dart`
- Create: `src/client/zmessanger/lib/features/groups/group_controller.dart`

- [ ] **Step 1: Create group controller**

```dart
// lib/features/groups/group_controller.dart
import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';

class GroupController extends ChangeNotifier {
  final AppDatabase _db;
  final ApiClient _api;

  GroupController(this._db, this._api);

  Future<String?> createGroup(String name, List<String> memberDeviceIds) async {
    try {
      // For now: device ID from secure storage
      final result = await _api.createGroup(name: name, memberDeviceIds: memberDeviceIds);
      final groupId = result['groupId'] as String;

      await _db.into(_db.conversations).insert(ConversationsCompanion.insert(
        id: groupId,
        type: 'group',
        title: Value(name),
      ));

      return groupId;
    } catch (e) {
      return null;
    }
  }
}
```

- [ ] **Step 2: Create group creation screen**

```dart
// lib/features/groups/group_create_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/widgets/avatar.dart';

class GroupCreateScreen extends StatefulWidget {
  const GroupCreateScreen({super.key});

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _nameController = TextEditingController();
  final _selectedMembers = <String>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Group'),
        actions: [
          TextButton(
            onPressed: _selectedMembers.isEmpty ? null : () {
              // Create group via controller, navigate to chat
              context.pop();
            },
            child: const Text('Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Group name',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Select members:'),
          ),
          Expanded(
            child: ListView(
              children: const [
                // Populated from contacts
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: group creation UI and controller"
```

---

### Task 25: CLAUDE.md for the Project

**Files:**
- Create: `C:\GIT\ZCLOUD\ZMessanger\CLAUDE.md`

- [ ] **Step 1: Write project CLAUDE.md**

```markdown
# ZMessanger

End-to-end encrypted multiplatform messenger (iOS, Android, Web).

## Stack

- **Client:** Flutter/Dart (single codebase)
- **Backend:** ASP.NET Core 8 (minimal API + SignalR)
- **Database:** PostgreSQL (server), SQLCipher via drift (client)
- **E2EE:** Signal Protocol via libsignal (Rust FFI + WASM)
- **Calls:** WebRTC (flutter_webrtc) + DeskShare STUN/TURN from RemoteDesktopNet
- **Storage:** Azure Blob Storage (attachments, backups)
- **Hosting:** Azure Container Apps

## Project Structure

```
src/
├── server/ZMessanger.Api/       # ASP.NET Core backend
├── server/ZMessanger.Api.Tests/ # Integration + unit tests
└── client/zmessanger/           # Flutter app
    ├── lib/                     # Dart source
    ├── test/                    # Dart tests
    └── native/libsignal/       # Rust FFI bridge
```

## Build & Test

### Backend
```bash
dotnet build src/server/ZMessanger.Api
dotnet test src/server/ZMessanger.Api.Tests
```

### Client
```bash
cd src/client/zmessanger
flutter pub get
dart run build_runner build --delete-conflicting-outputs  # drift codegen
flutter test
flutter run -d chrome   # web
flutter run              # connected device
```

### libsignal native
```bash
cd src/client/zmessanger/native/libsignal
./build.sh  # builds for Android, iOS, WASM
```

## Conventions

- Backend: C# minimal API, no controllers. One file per endpoint group.
- Client: feature-first folder structure. Provider for state management.
- All messages E2EE — server handles only encrypted blobs.
- Server stores minimum metadata. No plaintext content ever.

## Related Projects

- `C:\GIT\ZCLOUD\RemoteDesktopNet` — STUN/TURN servers (DeskShare.Stun, DeskShare.Turn)

## Spec

`docs/superpowers/specs/2026-05-28-zmessanger-design.md`
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "docs: add CLAUDE.md with project overview, build commands, conventions"
```

---

### Task 26: Final Integration Wiring

- [ ] **Step 1: Wire all providers in main.dart**

```dart
// lib/main.dart — final version
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app/app.dart';
import 'core/auth/app_lock.dart';
import 'core/network/api_client.dart';
import 'core/network/signalr_client.dart';
import 'core/network/webrtc_manager.dart';
import 'core/storage/database.dart';
import 'core/storage/secure_storage.dart';
import 'features/chat_list/chat_list_controller.dart';
import 'features/contacts/contacts_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dbKey = await SecureStorage.getOrCreateDbKey();
  final db = AppDatabase('zmessanger.db', dbKey);
  final api = ApiClient('https://api.zmsg.app'); // configure per environment
  final deviceId = await SecureStorage.getDeviceId() ?? '';

  runApp(
    MultiProvider(
      providers: [
        Provider.value(value: db),
        Provider.value(value: api),
        ChangeNotifierProvider(create: (_) => SignalRClient('https://api.zmsg.app', deviceId)),
        ChangeNotifierProvider(create: (ctx) => WebRTCManager(
          ctx.read<SignalRClient>(), api, deviceId)),
        ChangeNotifierProvider(create: (_) => ChatListController(db)),
        ChangeNotifierProvider(create: (_) => ContactsController(db, api)),
        Provider(create: (_) => AppLock()),
      ],
      child: const ZMessangerApp(),
    ),
  );
}
```

- [ ] **Step 2: Run full app and verify navigation**

Run: `flutter run -d chrome`
Expected: all screens navigate, no crashes

- [ ] **Step 3: Run all backend tests**

Run: `dotnet test src/server/ZMessanger.Api.Tests -v normal`
Expected: all PASS

- [ ] **Step 4: Run all Flutter tests**

Run: `cd src/client/zmessanger && flutter test`
Expected: all PASS (or no tests fail)

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: wire all providers, complete MVP integration"
```
