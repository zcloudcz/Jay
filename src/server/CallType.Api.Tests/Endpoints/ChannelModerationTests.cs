// ---------------------------------------------------------------------------
// ChannelModerationTests.cs - Integration tests for channel moderation
// ---------------------------------------------------------------------------
// Contract: docs/superpowers/specs/2026-11-05-channel-moderation-contract.md
// sections 2-4 (server). Real PostgreSQL + Azurite (Testcontainers), a real
// SignalR client for the tombstone / ChannelDeleted events.
//
// Every test runs on its OWN derived factory (StartAsync) for two reasons:
//  1. The operator allowlist (Moderation:OperatorAccountIds) has to contain an
//     account id the server generates during the test. The id is written into
//     the factory's IConfiguration BEFORE the first /admin request, i.e.
//     before IOptions<ModerationOptions> is first resolved and cached.
//  2. A startup filter gives every request its own random remote IP, so the
//     per-IP "auth" limiter (10/min, shared by all TestServer requests as
//     "unknown") cannot turn the many device registrations of these tests
//     into flaky 429s. Rate limiting itself is covered by RateLimitTests.
//
// TOTP without sleeping: enrolment is confirmed with the CURRENT time step,
// the operator session uses the NEXT one (same trick as
// IntegrationTestBase.EnrollAndVerifyMfaAsync); a second session in the same
// test uses one of the backup codes.
// ---------------------------------------------------------------------------

using System.Collections.Concurrent;
using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using CallType.Api.Data;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace CallType.Api.Tests.Endpoints;

public class ChannelModerationTests : IntegrationTestBase
{
    private static readonly string AuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    private sealed record TestDevice(Guid DeviceId, string Token, HttpClient Http, string Handle);

    private sealed record Operator(Guid AccountId, string Email, byte[] Secret, List<string> BackupCodes, HttpClient Http);

    private WebApplicationFactory<Program> _factory = null!;

    /// <summary>Raw body of every response, with the device (or operator) that received it.</summary>
    private readonly List<(Guid Caller, string Body)> _responses = [];

    // -----------------------------------------------------------------------
    // Fixture helpers
    // -----------------------------------------------------------------------

    /// <summary>See the file header, reason 2.</summary>
    private sealed class RandomRemoteIpStartupFilter : IStartupFilter
    {
        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
        {
            app.Use((context, nextMiddleware) =>
            {
                context.Connection.RemoteIpAddress = new IPAddress(Random.Shared.NextInt64(0x01000000, 0xDF000000));
                return nextMiddleware(context);
            });
            next(app);
        };
    }

    private WebApplicationFactory<Program> StartAsync()
    {
        _factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureServices(services => services.AddSingleton<IStartupFilter, RandomRemoteIpStartupFilter>()));
        return _factory;
    }

    /// <summary>Puts accounts on the operator allowlist. Call before the first /admin request.</summary>
    private void AllowOperators(params Guid[] accountIds)
    {
        var config = _factory.Services.GetRequiredService<IConfiguration>();
        for (var i = 0; i < accountIds.Length; i++)
            config[$"Moderation:OperatorAccountIds:{i}"] = accountIds[i].ToString();
    }

    /// <summary>Puts device handles on the operator allowlist. Call before the first /admin request.</summary>
    private void AllowOperatorHandles(params string[] handles)
    {
        var config = _factory.Services.GetRequiredService<IConfiguration>();
        for (var i = 0; i < handles.Length; i++)
            config[$"Moderation:OperatorHandles:{i}"] = handles[i];
    }

    private async Task<TestDevice> NewDeviceAsync(bool isBot = false, string? displayName = null)
    {
        var http = _factory.CreateClient();
        var reg = await http.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]),
            isBot
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created, await reg.Content.ReadAsStringAsync());
        var regBody = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var deviceId = regBody.GetProperty("deviceId").GetGuid();

        var tokenResponse = await http.PostAsJsonAsync("/auth/token", new
        {
            deviceId,
            deviceSecret = regBody.GetProperty("deviceSecret").GetString()
        });
        tokenResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (displayName is not null)
            (await http.PutAsJsonAsync($"/devices/{deviceId}/profile", new { displayName }))
                .IsSuccessStatusCode.Should().BeTrue();
        return new TestDevice(deviceId, token, http, regBody.GetProperty("userHandle").GetString()!);
    }

    /// <summary>Registers an account (fresh e-mail), links the device. Returns (accountId, email).</summary>
    private static async Task<(Guid AccountId, string Email)> RegisterAccountAsync(TestDevice device)
    {
        var email = $"moderation-{Guid.NewGuid():N}@example.com";
        var response = await device.Http.PostAsJsonAsync("/accounts", new { email, authKey = AuthKey });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetGuid();
        (await device.Http.PostAsJsonAsync($"/accounts/{accountId}/devices/{device.DeviceId}", new { authKey = AuthKey }))
            .StatusCode.Should().Be(HttpStatusCode.OK);
        return (accountId, email);
    }

    private async Task<TestDevice> NewOwnerAsync()
    {
        var device = await NewDeviceAsync();
        await RegisterAccountAsync(device);
        return device;
    }

    /// <summary>Enrols TOTP (confirmed with the previous step). Returns the secret and the backup codes.</summary>
    private static async Task<(byte[] Secret, List<string> BackupCodes)> EnrollMfaAsync(TestDevice device, Guid accountId)
    {
        var start = await device.Http.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/start", new { authKey = AuthKey });
        start.StatusCode.Should().Be(HttpStatusCode.OK);
        var secret = Base32.Decode((await start.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("secretBase32").GetString()!);

        var confirmStep = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / TotpService.Period;
        var confirm = await device.Http.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/confirm",
            new { code = TotpService.ComputeCode(secret, confirmStep) });
        confirm.StatusCode.Should().Be(HttpStatusCode.OK);
        var codes = (await confirm.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("backupCodes")
            .EnumerateArray().Select(c => c.GetString()!).ToList();
        return (secret, codes);
    }

    /// <summary>
    /// Code of the NEXT step: always newer than the enrolment confirmation
    /// (current step), and like it accepted across one step boundary (the
    /// server allows -1/0/+1), so a slow runner cannot push it out of the window.
    /// </summary>
    private static string CurrentCode(byte[] secret) =>
        TotpService.ComputeCode(secret, DateTimeOffset.UtcNow.ToUnixTimeSeconds() / TotpService.Period + 1);

    /// <summary>
    /// Account with MFA, NOT yet allowlisted and without a session. Use
    /// AllowOperators + OpenSessionAsync afterwards.
    /// </summary>
    private async Task<(Guid AccountId, string Email, byte[] Secret, List<string> BackupCodes)> NewMfaAccountAsync()
    {
        var device = await NewDeviceAsync();
        var (accountId, email) = await RegisterAccountAsync(device);
        var (secret, codes) = await EnrollMfaAsync(device, accountId);
        return (accountId, email, secret, codes);
    }

    private async Task<HttpResponseMessage> PostSessionAsync(string email, string authKey, string? code = null, string? backupCode = null)
    {
        using var http = _factory.CreateClient();
        return await http.PostAsJsonAsync("/admin/session", new { email, authKey, code, backupCode });
    }

    /// <summary>The usual start of a test: factory + one allowlisted operator with a live session.</summary>
    private async Task<Operator> StartWithOperatorAsync()
    {
        StartAsync();
        var (accountId, email, secret, codes) = await NewMfaAccountAsync();
        AllowOperators(accountId);

        var session = await PostSessionAsync(email, AuthKey, CurrentCode(secret));
        session.StatusCode.Should().Be(HttpStatusCode.OK, await session.Content.ReadAsStringAsync());
        var token = (await session.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        var http = _factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return new Operator(accountId, email, secret, codes, http);
    }

    private async Task<HttpResponseMessage> SendAsync(TestDevice device, HttpMethod method, string url, object? body = null)
    {
        using var request = new HttpRequestMessage(method, url);
        if (body is not null) request.Content = JsonContent.Create(body);
        var response = await device.Http.SendAsync(request);
        _responses.Add((device.DeviceId, await response.Content.ReadAsStringAsync()));
        return response;
    }

    private async Task<HttpResponseMessage> AdminAsync(Operator op, HttpMethod method, string url, object? body = null)
    {
        using var request = new HttpRequestMessage(method, url);
        if (body is not null) request.Content = JsonContent.Create(body);
        var response = await op.Http.SendAsync(request);
        _responses.Add((op.AccountId, await response.Content.ReadAsStringAsync()));
        return response;
    }

    private static async Task<JsonElement> JsonAsync(HttpResponseMessage response) =>
        await response.Content.ReadFromJsonAsync<JsonElement>();

    private static async Task<string?> CodeAsync(HttpResponseMessage response) =>
        (await JsonAsync(response)).TryGetProperty("code", out var code) ? code.GetString() : null;

    private async Task<Guid> CreateChannelAsync(TestDevice owner, string name = "News")
    {
        var response = await SendAsync(owner, HttpMethod.Post, "/channels", new { name, description = "Public updates" });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        return (await JsonAsync(response)).GetProperty("channelId").GetGuid();
    }

    private async Task FollowAsync(TestDevice device, Guid channelId) =>
        (await SendAsync(device, HttpMethod.Post, $"/channels/{channelId}/follow"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

    private async Task<Guid> PostTextAsync(TestDevice author, Guid channelId, string text = "hello")
    {
        var postId = Guid.NewGuid();
        var response = await SendAsync(author, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId, kind = "text", body = text });
        response.StatusCode.Should().Be(HttpStatusCode.Created, await response.Content.ReadAsStringAsync());
        return postId;
    }

    private async Task<long> ReportAsync(TestDevice reporter, Guid channelId, Guid? postId, string reason,
        string? category = null, string? contactEmail = null, bool? goodFaith = null)
    {
        var response = await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report",
            new { postId, reason, category, contactEmail, goodFaith });
        response.StatusCode.Should().Be(HttpStatusCode.OK, await response.Content.ReadAsStringAsync());
        return (await JsonAsync(response)).GetProperty("reportId").GetInt64();
    }

    private async Task<HttpResponseMessage> DecideAsync(Operator op, object body) =>
        await AdminAsync(op, HttpMethod.Post, "/admin/decisions", body);

    private async Task<T> DbAsync<T>(Func<AppDbContext, Task<T>> query)
    {
        using var scope = _factory.Services.CreateScope();
        return await query(scope.ServiceProvider.GetRequiredService<AppDbContext>());
    }

    private HubConnection CreateHubConnection(TestDevice device)
    {
        var server = _factory.Server;
        return new HubConnectionBuilder()
            .WithUrl($"{server.BaseAddress}hub?access_token={device.Token}", options =>
                options.HttpMessageHandlerFactory = _ => server.CreateHandler())
            .Build();
    }

    private static async Task WaitForAsync(Func<bool> condition, string because)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException($"Timed out waiting: {because}");
            await Task.Delay(50);
        }
    }

    // -----------------------------------------------------------------------
    // 4: allowlist, session, token separation
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Admin_api_is_404_while_no_operator_is_configured()
    {
        StartAsync();
        var device = await NewDeviceAsync();

        (await device.Http.GetAsync("/admin/summary")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await PostSessionAsync("x@example.com", AuthKey, "000000")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        using var anonymous = _factory.CreateClient();
        (await anonymous.GetAsync("/admin/reports")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Session_checks_credentials_allowlist_mfa_and_code()
    {
        StartAsync();
        var op = await NewMfaAccountAsync();
        var outsider = await NewMfaAccountAsync();
        var noMfaDevice = await NewDeviceAsync();
        var (noMfaAccount, noMfaEmail) = await RegisterAccountAsync(noMfaDevice);
        AllowOperators(op.AccountId, noMfaAccount);

        var wrongKey = Convert.ToBase64String(new byte[16]);
        var badKey = await PostSessionAsync(op.Email, wrongKey, CurrentCode(op.Secret));
        badKey.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await CodeAsync(badKey)).Should().Be("invalid_credentials");
        (await CodeAsync(await PostSessionAsync("nobody@example.com", AuthKey, "123456"))).Should().Be("invalid_credentials");

        var notOperator = await PostSessionAsync(outsider.Email, AuthKey, CurrentCode(outsider.Secret));
        notOperator.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(notOperator)).Should().Be("not_an_operator");

        var noMfa = await PostSessionAsync(noMfaEmail, AuthKey, "123456");
        noMfa.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(noMfa)).Should().Be("mfa_not_enabled");

        var badCode = await PostSessionAsync(op.Email, AuthKey, "000000");
        badCode.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await CodeAsync(badCode)).Should().Be("mfa_invalid_code");
        var missingCode = await PostSessionAsync(op.Email, AuthKey);
        missingCode.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await CodeAsync(missingCode)).Should().Be("mfa_invalid_code");

        // E-mail is matched case-insensitively like /accounts/login.
        var ok = await PostSessionAsync(op.Email.ToUpperInvariant(), AuthKey, CurrentCode(op.Secret));
        ok.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await JsonAsync(ok);
        body.GetProperty("accountId").GetGuid().Should().Be(op.AccountId);
        body.GetProperty("email").GetString().Should().Be(op.Email);
        var expiresAt = body.GetProperty("expiresAt").GetDateTimeOffset();
        expiresAt.Should().BeCloseTo(DateTimeOffset.UtcNow.AddMinutes(30), TimeSpan.FromMinutes(1));

        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(body.GetProperty("token").GetString());
        jwt.Subject.Should().Be(op.AccountId.ToString());
        jwt.Claims.Should().Contain(c => c.Type == "scope" && c.Value == "moderation");
        jwt.Claims.Should().Contain(c => c.Type == "amr" && c.Value == "totp");

        // A backup code is accepted instead of a TOTP code, once.
        (await PostSessionAsync(op.Email, AuthKey, backupCode: op.BackupCodes[0])).StatusCode.Should().Be(HttpStatusCode.OK);
        (await PostSessionAsync(op.Email, AuthKey, backupCode: op.BackupCodes[0])).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Operator_allowlisted_by_device_handle_gets_a_session_until_the_device_is_unlinked()
    {
        StartAsync();
        var device = await NewDeviceAsync();
        var (accountId, email) = await RegisterAccountAsync(device);
        var (secret, codes) = await EnrollMfaAsync(device, accountId);
        var outsider = await NewMfaAccountAsync();
        // Only handles configured (no account ids), written in lower case
        // with stray whitespace: matching is case-insensitive like
        // GET /devices/by-handle, and the handles alone enable /admin.
        AllowOperatorHandles($"  {device.Handle.ToLowerInvariant()} ");

        var notOperator = await PostSessionAsync(outsider.Email, AuthKey, CurrentCode(outsider.Secret));
        notOperator.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(notOperator)).Should().Be("not_an_operator");

        var session = await PostSessionAsync(email, AuthKey, CurrentCode(secret));
        session.StatusCode.Should().Be(HttpStatusCode.OK, await session.Content.ReadAsStringAsync());
        var body = await JsonAsync(session);
        body.GetProperty("accountId").GetGuid().Should().Be(accountId);

        using var http = _factory.CreateClient();
        http.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", body.GetProperty("token").GetString());
        (await http.GetAsync("/admin/summary")).StatusCode.Should().Be(HttpStatusCode.OK);

        // Unlinking the device takes the role away from the live session and
        // from new sessions (the per-call re-check reads the current links).
        using (var scope = _factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await db.AccountDevices.Where(ad => ad.AccountId == accountId && ad.DeviceId == device.DeviceId)
                .ExecuteDeleteAsync();
        }
        var revoked = await http.GetAsync("/admin/summary");
        revoked.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(revoked)).Should().Be("not_an_operator");
        var again = await PostSessionAsync(email, AuthKey, backupCode: codes[0]);
        again.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(again)).Should().Be("not_an_operator");
    }

    [Fact]
    public async Task Operator_and_device_tokens_are_not_interchangeable()
    {
        var op = await StartWithOperatorAsync();
        var device = await NewOwnerAsync();

        // Device token on /admin -> 403 operator_token_required (even for a
        // device of an account that is not the operator).
        var deviceOnAdmin = await SendAsync(device, HttpMethod.Get, "/admin/summary");
        deviceOnAdmin.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(deviceOnAdmin)).Should().Be("operator_token_required");

        // Operator token anywhere else -> 401, including the hub and refresh.
        (await op.Http.GetAsync("/channels/mine")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await op.Http.GetAsync($"/accounts/{op.AccountId}/devices")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await op.Http.PostAsync("/auth/refresh", null)).StatusCode.Should().Be(HttpStatusCode.Unauthorized);

        (await op.Http.GetAsync("/admin/summary")).StatusCode.Should().Be(HttpStatusCode.OK);

        // Removing the account from the allowlist cuts a live session. IOptions
        // caches the bound value per host, so prove it through a fresh factory
        // (same database and signing key) whose allowlist lacks the account.
        await using var other = _factory.WithWebHostBuilder(b => b.ConfigureAppConfiguration((_, c) =>
            c.AddInMemoryCollection(new Dictionary<string, string?> { ["Moderation:OperatorAccountIds:0"] = Guid.NewGuid().ToString() })));
        using var http = other.CreateClient();
        http.DefaultRequestHeaders.Authorization = op.Http.DefaultRequestHeaders.Authorization;
        var revoked = await http.GetAsync("/admin/summary");
        revoked.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CodeAsync(revoked)).Should().Be("not_an_operator");
    }

    // -----------------------------------------------------------------------
    // 3: report fields, receipt, reports/mine
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Report_validates_category_contact_and_good_faith_and_returns_a_receipt()
    {
        StartAsync();
        var owner = await NewOwnerAsync();
        var reporter = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner, "Shady");
        await FollowAsync(reporter, channelId);
        var postId = await PostTextAsync(owner, channelId, "buy now");

        async Task<string?> Rejected(object body)
        {
            var response = await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", body);
            response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            return await CodeAsync(response);
        }
        (await Rejected(new { reason = "x", category = "rude" })).Should().Be("invalid_category");
        (await Rejected(new { reason = "x", contactEmail = "not-an-address" })).Should().Be("invalid_contact");
        (await Rejected(new { reason = "x", contactEmail = new string('a', 250) + "@x.cz" })).Should().Be("invalid_contact");
        (await Rejected(new { reason = "x", category = "illegal" })).Should().Be("good_faith_required");
        (await Rejected(new { reason = "x", category = "illegal", goodFaith = false })).Should().Be("good_faith_required");

        // Old client body: no category -> "terms", answer is the 200 receipt.
        var before = DateTimeOffset.UtcNow.AddSeconds(-5);
        var old = await SendAsync(reporter, HttpMethod.Post, $"/channels/{channelId}/report", new { reason = "spam" });
        old.StatusCode.Should().Be(HttpStatusCode.OK);
        var receipt = await JsonAsync(old);
        var oldId = receipt.GetProperty("reportId").GetInt64();
        receipt.GetProperty("createdAt").GetDateTimeOffset().Should().BeAfter(before);

        var illegalId = await ReportAsync(reporter, channelId, postId, "scam", "illegal", " me@example.com ", true);
        illegalId.Should().BeGreaterThan(oldId);

        var stored = await DbAsync(db => db.ChannelReports.OrderBy(r => r.Id).ToListAsync());
        stored.Select(r => r.Category).Should().Equal("terms", "illegal");
        stored[1].ContactEmail.Should().Be("me@example.com");
        stored[1].GoodFaith.Should().BeTrue();
        stored.Should().OnlyContain(r => r.Status == "open" && r.ResolvedAt == null);

        // reports/mine: this device's reports, newest first, with channel name/handle.
        var stranger = await NewDeviceAsync();
        (await JsonAsync(await SendAsync(stranger, HttpMethod.Get, "/channels/reports/mine"))).GetArrayLength().Should().Be(0);

        var mine = await JsonAsync(await SendAsync(reporter, HttpMethod.Get, "/channels/reports/mine"));
        mine.GetArrayLength().Should().Be(2);
        var newest = mine[0];
        newest.GetProperty("reportId").GetInt64().Should().Be(illegalId);
        newest.GetProperty("channelId").GetGuid().Should().Be(channelId);
        newest.GetProperty("channelName").GetString().Should().Be("Shady");
        newest.GetProperty("channelHandle").GetString().Should().StartWith("CH-");
        newest.GetProperty("postId").GetGuid().Should().Be(postId);
        newest.GetProperty("category").GetString().Should().Be("illegal");
        newest.GetProperty("status").GetString().Should().Be("open");
        newest.GetProperty("resolvedAt").ValueKind.Should().Be(JsonValueKind.Null);
        mine[1].GetProperty("postId").ValueKind.Should().Be(JsonValueKind.Null);

        // Still listed after the owner deletes the channel.
        (await SendAsync(owner, HttpMethod.Delete, $"/channels/{channelId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        var afterDelete = await JsonAsync(await SendAsync(reporter, HttpMethod.Get, "/channels/reports/mine"));
        afterDelete[0].GetProperty("channelName").GetString().Should().Be("Shady");
    }

    // -----------------------------------------------------------------------
    // 4.2 / 4.3 / 4.4: summary, queue, case detail
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Queue_groups_by_subject_filters_pages_and_never_exposes_reporters()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var reporterA = await NewDeviceAsync();
        var reporterB = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner, "Busy");
        await FollowAsync(reporterA, channelId);
        await FollowAsync(reporterB, channelId);
        var postId = await PostTextAsync(owner, channelId, "bad post");
        var otherPost = await PostTextAsync(owner, channelId, "another");

        await ReportAsync(reporterA, channelId, postId, "first", "spam");
        await ReportAsync(reporterB, channelId, postId, new string('r', 400), "illegal", "b@example.com", true);
        await ReportAsync(reporterA, channelId, null, "whole channel", "terms");
        await ReportAsync(reporterB, channelId, otherPost, "other", "terms");

        var summary = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/summary"));
        summary.GetProperty("openReports").GetInt32().Should().Be(4);
        summary.GetProperty("openSubjects").GetInt32().Should().Be(3);
        summary.GetProperty("oldestOpenAt").ValueKind.Should().Be(JsonValueKind.String);
        summary.GetProperty("suspendedChannels").GetInt32().Should().Be(0);
        summary.GetProperty("decisionsLast30Days").GetInt32().Should().Be(0);

        var queue = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/reports"));
        var items = queue.GetProperty("items");
        items.GetArrayLength().Should().Be(3);
        queue.GetProperty("counts").GetProperty("open").GetInt32().Should().Be(3);
        queue.GetProperty("counts").GetProperty("resolved").GetInt32().Should().Be(0);
        queue.GetProperty("nextCursor").ValueKind.Should().Be(JsonValueKind.Null);

        // Open queue = oldest first, so the doubly reported post leads.
        var first = items[0];
        first.GetProperty("subjectType").GetString().Should().Be("post");
        first.GetProperty("postId").GetGuid().Should().Be(postId);
        first.GetProperty("status").GetString().Should().Be("open");
        first.GetProperty("reportCount").GetInt32().Should().Be(2);
        first.GetProperty("categories").GetProperty("spam").GetInt32().Should().Be(1);
        first.GetProperty("categories").GetProperty("illegal").GetInt32().Should().Be(1);
        first.GetProperty("categories").GetProperty("terms").GetInt32().Should().Be(0);
        first.GetProperty("latestReason").GetString().Should().HaveLength(280);
        first.GetProperty("channel").GetProperty("ownerHandle").GetString().Should().Be(owner.Handle);
        first.GetProperty("channel").GetProperty("status").GetString().Should().Be("active");
        first.GetProperty("post").GetProperty("body").GetString().Should().Be("bad post");
        first.GetProperty("post").GetProperty("byBot").GetBoolean().Should().BeFalse();
        first.GetProperty("priorDecisions").GetArrayLength().Should().Be(0);
        items[1].GetProperty("subjectType").GetString().Should().Be("channel");
        items[1].GetProperty("post").ValueKind.Should().Be(JsonValueKind.Null);

        // Filters.
        var illegal = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/reports?category=illegal"));
        illegal.GetProperty("items").EnumerateArray().Select(i => i.GetProperty("postId").GetGuid()).Should().Equal(postId);
        var channelsOnly = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/reports?subjectType=channel"));
        channelsOnly.GetProperty("items").GetArrayLength().Should().Be(1);
        (await AdminAsync(op, HttpMethod.Get, "/admin/reports?status=bogus")).StatusCode.Should().Be(HttpStatusCode.BadRequest);

        // Cursor paging over the open queue.
        var page1 = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/reports?limit=2"));
        page1.GetProperty("items").GetArrayLength().Should().Be(2);
        var cursor = page1.GetProperty("nextCursor").GetString()!;
        var page2 = await JsonAsync(await AdminAsync(op, HttpMethod.Get, $"/admin/reports?limit=2&cursor={Uri.EscapeDataString(cursor)}"));
        page2.GetProperty("items").EnumerateArray().Select(i => i.GetProperty("postId").GetGuid()).Should().Equal(otherPost);
        page2.GetProperty("nextCursor").ValueKind.Should().Be(JsonValueKind.Null);

        // Dismiss the channel subject -> it moves to the resolved tab.
        (await DecideAsync(op, new { channelId, action = "dismiss", explanation = "Nothing wrong." }))
            .StatusCode.Should().Be(HttpStatusCode.Created);
        var resolved = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/reports?status=resolved"));
        resolved.GetProperty("items").EnumerateArray().Select(i => i.GetProperty("subjectType").GetString()).Should().Equal("channel");
        resolved.GetProperty("items")[0].GetProperty("status").GetString().Should().Be("resolved");
        resolved.GetProperty("counts").GetProperty("open").GetInt32().Should().Be(2);
        resolved.GetProperty("counts").GetProperty("resolved").GetInt32().Should().Be(1);
        var all = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/reports?status=all"));
        all.GetProperty("items").GetArrayLength().Should().Be(3);

        // Case detail of the post: its 2 reports, context, contact e-mail.
        var detail = await JsonAsync(await AdminAsync(op, HttpMethod.Get, $"/admin/subjects/{channelId}?postId={postId}"));
        detail.GetProperty("post").GetProperty("postId").GetGuid().Should().Be(postId);
        detail.GetProperty("context").EnumerateArray().Select(p => p.GetProperty("postId").GetGuid()).Should().Equal(otherPost);
        var reports = detail.GetProperty("reports");
        reports.GetArrayLength().Should().Be(2);
        reports[0].GetProperty("category").GetString().Should().Be("illegal");
        reports[0].GetProperty("contactEmail").GetString().Should().Be("b@example.com");
        reports[0].GetProperty("goodFaith").GetBoolean().Should().BeTrue();
        reports[1].GetProperty("contactEmail").ValueKind.Should().Be(JsonValueKind.Null);
        detail.GetProperty("decisions").GetArrayLength().Should().Be(1); // the dismiss (operator sees all)

        var channelDetail = await JsonAsync(await AdminAsync(op, HttpMethod.Get, $"/admin/subjects/{channelId}"));
        channelDetail.GetProperty("post").ValueKind.Should().Be(JsonValueKind.Null);
        channelDetail.GetProperty("context").GetArrayLength().Should().Be(2);
        channelDetail.GetProperty("reports").GetArrayLength().Should().Be(1);
        (await AdminAsync(op, HttpMethod.Get, $"/admin/subjects/{Guid.NewGuid()}")).StatusCode.Should().Be(HttpStatusCode.NotFound);

        // No admin response ever mentions a reporter device.
        _responses.Where(r => r.Caller == op.AccountId).Should().NotContain(r =>
            r.Body.Contains(reporterA.DeviceId.ToString(), StringComparison.OrdinalIgnoreCase) ||
            r.Body.Contains(reporterB.DeviceId.ToString(), StringComparison.OrdinalIgnoreCase));
    }

    // -----------------------------------------------------------------------
    // 4.6: validation
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Decision_validation_codes()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var channelId = await CreateChannelAsync(owner);
        var postId = await PostTextAsync(owner, channelId);

        async Task Expect(object body, HttpStatusCode status, string code)
        {
            var response = await DecideAsync(op, body);
            response.StatusCode.Should().Be(status, await response.Content.ReadAsStringAsync());
            (await CodeAsync(response)).Should().Be(code);
        }

        await Expect(new { channelId, action = "ban", explanation = "x" }, HttpStatusCode.BadRequest, "invalid_action");
        await Expect(new { channelId, action = "remove_post", ground = "terms", rule = "K1", explanation = "x" },
            HttpStatusCode.BadRequest, "post_required");
        await Expect(new { channelId, postId, action = "suspend_channel", ground = "terms", rule = "K1", explanation = "x", suspendDays = 3 },
            HttpStatusCode.BadRequest, "post_not_allowed");
        await Expect(new { channelId, postId, action = "remove_post", explanation = "x" }, HttpStatusCode.BadRequest, "invalid_ground");
        await Expect(new { channelId, postId, action = "remove_post", ground = "vibes", explanation = "x" }, HttpStatusCode.BadRequest, "invalid_ground");
        await Expect(new { channelId, postId, action = "remove_post", ground = "terms", rule = "K11", explanation = "x" },
            HttpStatusCode.BadRequest, "invalid_rule");
        await Expect(new { channelId, postId, action = "remove_post", ground = "terms", explanation = "x" },
            HttpStatusCode.BadRequest, "invalid_rule");
        await Expect(new { channelId, postId, action = "remove_post", ground = "illegal", legalGround = " ", explanation = "x" },
            HttpStatusCode.BadRequest, "legal_ground_required");
        await Expect(new { channelId, postId, action = "remove_post", ground = "illegal", legalGround = new string('l', 301), explanation = "x" },
            HttpStatusCode.BadRequest, "legal_ground_required");
        await Expect(new { channelId, postId, action = "remove_post", ground = "terms", rule = "K2", explanation = "  " },
            HttpStatusCode.BadRequest, "explanation_required");
        await Expect(new { channelId, action = "dismiss", explanation = new string('e', 2001) }, HttpStatusCode.BadRequest, "explanation_required");
        await Expect(new { channelId, action = "suspend_channel", ground = "terms", rule = "K3", explanation = "x", suspendDays = 0 },
            HttpStatusCode.BadRequest, "invalid_suspend_days");
        await Expect(new { channelId, action = "suspend_channel", ground = "terms", rule = "K3", explanation = "x", suspendDays = 366 },
            HttpStatusCode.BadRequest, "invalid_suspend_days");
        await Expect(new { channelId, action = "suspend_channel", ground = "terms", rule = "K3", explanation = "x" },
            HttpStatusCode.BadRequest, "invalid_suspend_days");
        await Expect(new { channelId, action = "restore_channel", explanation = "x" }, HttpStatusCode.Conflict, "not_suspended");
        await Expect(new { channelId = Guid.NewGuid(), action = "dismiss", explanation = "x" }, HttpStatusCode.NotFound, "channel_not_found");
        await Expect(new { channelId, postId = Guid.NewGuid(), action = "remove_post", ground = "terms", rule = "K1", explanation = "x" },
            HttpStatusCode.NotFound, "post_not_found");

        (await DbAsync(db => db.ModerationDecisions.CountAsync())).Should().Be(0);
    }

    // -----------------------------------------------------------------------
    // 4.6 effects + 3 statements
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Remove_post_tombstones_it_resolves_its_reports_and_tells_owner_and_reporter()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var follower = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);
        var postId = await PostTextAsync(owner, channelId, "illegal stuff");
        var keptPost = await PostTextAsync(owner, channelId, "fine");
        var postReport = await ReportAsync(follower, channelId, postId, "illegal", "illegal", null, true);
        var otherReport = await ReportAsync(follower, channelId, keptPost, "meh");

        var events = new ConcurrentQueue<JsonElement>();
        await using var hub = CreateHubConnection(follower);
        hub.On<JsonElement>("ReceiveChannelPost", events.Enqueue);
        await hub.StartAsync();
        await hub.InvokeAsync<List<Guid>>("JoinChannels");

        var response = await DecideAsync(op, new
        {
            channelId, postId, action = "remove_post", ground = "illegal",
            legalGround = "§ 356 trestního zákoníku", explanation = "  Incites hatred.  "
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var decision = await JsonAsync(response);
        decision.GetProperty("action").GetString().Should().Be("remove_post");
        decision.GetProperty("ground").GetString().Should().Be("illegal");
        decision.GetProperty("rule").ValueKind.Should().Be(JsonValueKind.Null);
        decision.GetProperty("explanation").GetString().Should().Be("Incites hatred.");
        decision.GetProperty("reportCount").GetInt32().Should().Be(1);
        decision.GetProperty("basedOnReports").GetBoolean().Should().BeTrue();
        decision.GetProperty("automated").GetBoolean().Should().BeFalse();
        decision.GetProperty("operatorAccountId").GetGuid().Should().Be(op.AccountId);
        decision.GetProperty("channelId").GetGuid().Should().Be(channelId);

        await WaitForAsync(() => events.Any(e => e.GetProperty("postId").GetGuid() == postId), "tombstone event");
        var tombstone = events.Single(e => e.GetProperty("postId").GetGuid() == postId);
        tombstone.GetProperty("deleted").GetBoolean().Should().BeTrue();
        tombstone.GetProperty("body").GetString().Should().BeEmpty();

        var feed = await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts"));
        feed.EnumerateArray().Single(p => p.GetProperty("postId").GetGuid() == postId)
            .GetProperty("deleted").GetBoolean().Should().BeTrue();

        // Only the post's report was actioned; the other subject stays open.
        var reports = await DbAsync(db => db.ChannelReports.ToDictionaryAsync(r => r.Id));
        reports[postReport].Status.Should().Be("actioned");
        reports[postReport].ResolvedAt.Should().NotBeNull();
        reports[postReport].DecisionId.Should().Be(decision.GetProperty("decisionId").GetInt64());
        reports[otherReport].Status.Should().Be("open");

        var mine = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/reports/mine"));
        mine.EnumerateArray().Single(r => r.GetProperty("reportId").GetInt64() == postReport)
            .GetProperty("status").GetString().Should().Be("actioned");

        // Statement for the owner; a follower has no access.
        var statements = await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/moderation"));
        statements.GetArrayLength().Should().Be(1);
        var statement = statements[0];
        statement.GetProperty("action").GetString().Should().Be("remove_post");
        statement.GetProperty("postId").GetGuid().Should().Be(postId);
        statement.GetProperty("legalGround").GetString().Should().Be("§ 356 trestního zákoníku");
        statement.GetProperty("basedOnReports").GetBoolean().Should().BeTrue();
        statement.GetProperty("automated").GetBoolean().Should().BeFalse();
        statement.TryGetProperty("operatorAccountId", out _).Should().BeFalse();
        (await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/moderation")).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Already removed -> 409.
        var again = await DecideAsync(op, new { channelId, postId, action = "remove_post", ground = "terms", rule = "K1", explanation = "x" });
        again.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await CodeAsync(again)).Should().Be("already_removed");

        // The case detail still shows the removed post's content to the operator.
        var detail = await JsonAsync(await AdminAsync(op, HttpMethod.Get, $"/admin/subjects/{channelId}?postId={postId}"));
        detail.GetProperty("post").GetProperty("deleted").GetBoolean().Should().BeTrue();
        detail.GetProperty("post").GetProperty("body").GetString().Should().Be("illegal stuff");
    }

    [Fact]
    public async Task Suspension_hides_the_channel_from_followers_and_blocks_activity_until_restored()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var admin = await NewDeviceAsync();
        var publisher = await NewDeviceAsync();
        var follower = await NewDeviceAsync();
        var newcomer = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{admin.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{publisher.DeviceId}", new { role = "publisher" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        await FollowAsync(follower, channelId);
        var postId = await PostTextAsync(owner, channelId);
        var channelReport = await ReportAsync(follower, channelId, null, "whole channel bad");
        var postReport = await ReportAsync(follower, channelId, postId, "post bad");

        var response = await DecideAsync(op, new
        {
            channelId, action = "suspend_channel", ground = "terms", rule = "k4", explanation = "Repeated spam.", suspendDays = 7
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created, await response.Content.ReadAsStringAsync());
        var decision = await JsonAsync(response);
        decision.GetProperty("rule").GetString().Should().Be("K4");
        decision.GetProperty("reportCount").GetInt32().Should().Be(2);
        var until = decision.GetProperty("suspendedUntil").GetDateTimeOffset();
        until.Should().BeCloseTo(DateTimeOffset.UtcNow.AddDays(7), TimeSpan.FromMinutes(1));

        // Every open report on the channel, its posts included, is actioned.
        var statuses = await DbAsync(db => db.ChannelReports.ToDictionaryAsync(r => r.Id, r => r.Status));
        statuses[channelReport].Should().Be("actioned");
        statuses[postReport].Should().Be("actioned");

        async Task ExpectSuspended(HttpResponseMessage r)
        {
            r.StatusCode.Should().Be(HttpStatusCode.Forbidden);
            (await CodeAsync(r)).Should().Be("channel_suspended");
        }

        await ExpectSuspended(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts"));
        await ExpectSuspended(await SendAsync(follower, HttpMethod.Put, $"/channels/{channelId}/posts/{postId}/reaction", new { emoji = "\U0001F44D" }));
        await ExpectSuspended(await SendAsync(newcomer, HttpMethod.Post, $"/channels/{channelId}/follow"));
        await ExpectSuspended(await SendAsync(owner, HttpMethod.Post, $"/channels/{channelId}/posts",
            new { postId = Guid.NewGuid(), kind = "text", body = "still here" }));
        await ExpectSuspended(await SendAsync(publisher, HttpMethod.Post, $"/channels/{channelId}/posts",
            new { postId = Guid.NewGuid(), kind = "text", body = "still here" }));

        // The team still reads the feed; the profile shows the status to everyone.
        (await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/posts")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await SendAsync(admin, HttpMethod.Get, $"/channels/{channelId}/posts")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await SendAsync(publisher, HttpMethod.Get, $"/channels/{channelId}/posts")).StatusCode.Should().Be(HttpStatusCode.OK);
        var profile = await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}"));
        profile.GetProperty("status").GetString().Should().Be("suspended");
        profile.GetProperty("suspendedUntil").GetDateTimeOffset().Should().BeCloseTo(until, TimeSpan.FromSeconds(1));
        var mine = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/mine"));
        mine.EnumerateArray().Single().GetProperty("status").GetString().Should().Be("suspended");

        // Statements: owner, admin, publisher yes; follower no.
        foreach (var member in new[] { owner, admin, publisher })
        {
            var list = await JsonAsync(await SendAsync(member, HttpMethod.Get, $"/channels/{channelId}/moderation"));
            list.EnumerateArray().Select(s => s.GetProperty("action").GetString()).Should().Equal("suspend_channel");
        }
        (await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/moderation")).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var summary = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/summary"));
        summary.GetProperty("suspendedChannels").GetInt32().Should().Be(1);
        summary.GetProperty("openReports").GetInt32().Should().Be(0);

        // Restore: no ground needed, reports untouched, everything works again.
        var newReport = await ReportAsync(follower, channelId, null, "reported while suspended");
        var restore = await DecideAsync(op, new { channelId, action = "restore_channel", explanation = "Appeal accepted." });
        restore.StatusCode.Should().Be(HttpStatusCode.Created);
        (await JsonAsync(restore)).GetProperty("reportCount").GetInt32().Should().Be(0);
        (await DbAsync(db => db.ChannelReports.SingleAsync(r => r.Id == newReport))).Status.Should().Be("open");

        (await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await SendAsync(newcomer, HttpMethod.Post, $"/channels/{channelId}/follow")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        await PostTextAsync(owner, channelId, "back");
        (await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}"))).GetProperty("status").GetString().Should().Be("active");

        var again = await DecideAsync(op, new { channelId, action = "restore_channel", explanation = "again" });
        again.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await CodeAsync(again)).Should().Be("not_suspended");

        var ownerStatements = await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/moderation"));
        ownerStatements.EnumerateArray().Select(s => s.GetProperty("action").GetString())
            .Should().Equal("restore_channel", "suspend_channel");
        ownerStatements[0].GetProperty("basedOnReports").GetBoolean().Should().BeFalse();
    }

    [Fact]
    public async Task Terminate_deletes_the_channel_but_the_owner_still_reads_the_statement()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var admin = await NewDeviceAsync();
        var follower = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{admin.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        await FollowAsync(follower, channelId);
        var reportId = await ReportAsync(follower, channelId, null, "terror", "illegal", null, true);

        var deleted = new ConcurrentQueue<JsonElement>();
        await using var hub = CreateHubConnection(follower);
        hub.On<JsonElement>("ChannelDeleted", deleted.Enqueue);
        await hub.StartAsync();
        await hub.InvokeAsync<List<Guid>>("JoinChannels");

        var response = await DecideAsync(op, new
        {
            channelId, action = "terminate_channel", ground = "illegal", legalGround = "TCO Regulation (EU) 2021/784",
            explanation = "Terrorist content."
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        await WaitForAsync(() => !deleted.IsEmpty, "ChannelDeleted event");

        (await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await DbAsync(db => db.ChannelReports.SingleAsync(r => r.Id == reportId))).Status.Should().Be("actioned");

        var statements = await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/moderation"));
        statements.EnumerateArray().Select(s => s.GetProperty("action").GetString()).Should().Equal("terminate_channel");
        (await SendAsync(admin, HttpMethod.Get, $"/channels/{channelId}/moderation")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/moderation")).StatusCode.Should().Be(HttpStatusCode.NotFound);

        var reporterView = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/reports/mine"));
        reporterView[0].GetProperty("status").GetString().Should().Be("actioned");

        // The operator still finds it, flagged as deleted; channel actions are over.
        var found = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/channels?q=new"));
        found.EnumerateArray().Single(c => c.GetProperty("channelId").GetGuid() == channelId)
            .GetProperty("deleted").GetBoolean().Should().BeTrue();
        var suspend = await DecideAsync(op, new { channelId, action = "suspend_channel", ground = "terms", rule = "K1", explanation = "x", suspendDays = 1 });
        suspend.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await CodeAsync(suspend)).Should().Be("channel_deleted");
    }

    [Fact]
    public async Task Dismiss_resolves_reports_without_a_statement_for_the_owner()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var follower = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);
        var postId = await PostTextAsync(owner, channelId);
        var postReport = await ReportAsync(follower, channelId, postId, "dislike");
        var channelReport = await ReportAsync(follower, channelId, null, "dislike channel");

        // A ground sent with dismiss is ignored, not stored.
        var response = await DecideAsync(op, new { channelId, postId, action = "dismiss", ground = "terms", rule = "K1", explanation = "Opinion, allowed." });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var decision = await JsonAsync(response);
        decision.GetProperty("reportCount").GetInt32().Should().Be(1);
        decision.GetProperty("ground").ValueKind.Should().Be(JsonValueKind.Null);
        decision.GetProperty("rule").ValueKind.Should().Be(JsonValueKind.Null);

        var statuses = await DbAsync(db => db.ChannelReports.ToDictionaryAsync(r => r.Id, r => r.Status));
        statuses[postReport].Should().Be("dismissed");
        statuses[channelReport].Should().Be("open");

        (await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/moderation"))).GetArrayLength().Should().Be(0);
        var mine = await JsonAsync(await SendAsync(follower, HttpMethod.Get, "/channels/reports/mine"));
        var dismissed = mine.EnumerateArray().Single(r => r.GetProperty("reportId").GetInt64() == postReport);
        dismissed.GetProperty("status").GetString().Should().Be("dismissed");
        dismissed.GetProperty("resolvedAt").ValueKind.Should().Be(JsonValueKind.String);

        // The post is untouched.
        var feed = await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts"));
        feed[0].GetProperty("deleted").GetBoolean().Should().BeFalse();
    }

    // -----------------------------------------------------------------------
    // 3: publisher role, admins list, bot label and limit
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Publisher_posts_and_deletes_only_its_own_posts()
    {
        StartAsync();
        var owner = await NewOwnerAsync();
        var publisher = await NewDeviceAsync(displayName: "Newsletter");
        var channelId = await CreateChannelAsync(owner);

        var invalid = await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{publisher.DeviceId}", new { role = "owner" });
        invalid.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await CodeAsync(invalid)).Should().Be("invalid_role");

        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{publisher.DeviceId}", new { role = "publisher" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        var admins = await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/admins"));
        var entry = admins.EnumerateArray().Single();
        entry.GetProperty("deviceId").GetGuid().Should().Be(publisher.DeviceId);
        entry.GetProperty("role").GetString().Should().Be("publisher");
        entry.GetProperty("isBot").GetBoolean().Should().BeFalse();
        entry.GetProperty("handle").GetString().Should().Be(publisher.Handle);
        entry.GetProperty("displayName").GetString().Should().Be("Newsletter");

        (await JsonAsync(await SendAsync(publisher, HttpMethod.Get, $"/channels/{channelId}"))).GetProperty("role").GetString()
            .Should().Be("publisher");
        (await JsonAsync(await SendAsync(publisher, HttpMethod.Get, "/channels/mine"))).EnumerateArray().Single()
            .GetProperty("role").GetString().Should().Be("publisher");

        var own = await PostTextAsync(publisher, channelId, "issue #1");
        var ownersPost = await PostTextAsync(owner, channelId, "owner's");
        (await SendAsync(publisher, HttpMethod.Get, $"/channels/{channelId}/posts")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await SendAsync(publisher, HttpMethod.Delete, $"/channels/{channelId}/posts/{ownersPost}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(publisher, HttpMethod.Delete, $"/channels/{channelId}/posts/{own}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await SendAsync(publisher, HttpMethod.Delete, $"/channels/{channelId}/posts/{Guid.NewGuid()}")).StatusCode.Should().Be(HttpStatusCode.NotFound);

        // No management rights.
        (await SendAsync(publisher, HttpMethod.Patch, $"/channels/{channelId}", new { name = "Mine now" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(publisher, HttpMethod.Put, $"/channels/{channelId}/admins/{publisher.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(publisher, HttpMethod.Get, $"/channels/{channelId}/admins")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await SendAsync(publisher, HttpMethod.Delete, $"/channels/{channelId}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Promote to admin by PUT without a body (old clients) -> role updated, more rights.
        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{publisher.DeviceId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/admins"))).EnumerateArray().Single()
            .GetProperty("role").GetString().Should().Be("admin");
        (await SendAsync(publisher, HttpMethod.Delete, $"/channels/{channelId}/posts/{ownersPost}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await SendAsync(publisher, HttpMethod.Patch, $"/channels/{channelId}", new { name = "Edited" })).StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Bot_posts_are_labelled_and_limited_per_day()
    {
        StartAsync();
        var owner = await NewOwnerAsync();
        var bot = await NewDeviceAsync(isBot: true, displayName: "Hermes");
        var follower = await NewDeviceAsync();
        var channelId = await CreateChannelAsync(owner);
        await FollowAsync(follower, channelId);
        (await SendAsync(owner, HttpMethod.Put, $"/channels/{channelId}/admins/{bot.DeviceId}", new { role = "publisher" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{channelId}/admins"))).EnumerateArray().Single()
            .GetProperty("isBot").GetBoolean().Should().BeTrue();

        var events = new ConcurrentQueue<JsonElement>();
        await using var hub = CreateHubConnection(follower);
        hub.On<JsonElement>("ReceiveChannelPost", events.Enqueue);
        await hub.StartAsync();
        await hub.InvokeAsync<List<Guid>>("JoinChannels");

        var firstId = Guid.NewGuid();
        var first = await SendAsync(bot, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId = firstId, kind = "text", body = "issue 1" });
        first.StatusCode.Should().Be(HttpStatusCode.Created);
        (await JsonAsync(first)).GetProperty("byBot").GetBoolean().Should().BeTrue();
        await WaitForAsync(() => !events.IsEmpty, "bot post event");
        events.Single().GetProperty("byBot").GetBoolean().Should().BeTrue();

        var humanPost = await PostTextAsync(owner, channelId, "human");
        var feed = await JsonAsync(await SendAsync(follower, HttpMethod.Get, $"/channels/{channelId}/posts"));
        feed.EnumerateArray().ToDictionary(p => p.GetProperty("postId").GetGuid(), p => p.GetProperty("byBot").GetBoolean())
            .Should().BeEquivalentTo(new Dictionary<Guid, bool> { [firstId] = true, [humanPost] = false });

        // One deleted post still counts (deleting must not reset the budget).
        (await SendAsync(bot, HttpMethod.Delete, $"/channels/{channelId}/posts/{firstId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        for (var i = 2; i <= 20; i++) await PostTextAsync(bot, channelId, $"issue {i}");

        var over = await SendAsync(bot, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId = Guid.NewGuid(), kind = "text", body = "issue 21" });
        over.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        (await CodeAsync(over)).Should().Be("bot_post_limit");

        // An idempotent repeat of a stored post is neither refused nor counted.
        var repeat = await SendAsync(bot, HttpMethod.Post, $"/channels/{channelId}/posts", new { postId = firstId, kind = "text", body = "issue 1" });
        repeat.StatusCode.Should().Be(HttpStatusCode.OK);
        (await JsonAsync(repeat)).GetProperty("byBot").GetBoolean().Should().BeTrue();

        // Humans have no such limit.
        await PostTextAsync(owner, channelId, "human again");
        (await DbAsync(db => db.ChannelPosts.CountAsync(p => p.AuthorDeviceId == bot.DeviceId))).Should().Be(20);
    }

    // -----------------------------------------------------------------------
    // 4.5 / 4.7 / 4.8: attachments, channel search, decision log + CSV
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Operator_searches_channels_reads_attachments_and_exports_the_decision_log()
    {
        var op = await StartWithOperatorAsync();
        var owner = await NewOwnerAsync();
        var alpha = await CreateChannelAsync(owner, "Alpha 50% news");
        var beta = await CreateChannelAsync(owner, "Beta");

        var file = new ByteArrayContent([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
        file.Headers.ContentType = new MediaTypeHeaderValue("image/png");
        var upload = await owner.Http.PostAsync($"/channels/{alpha}/attachments",
            new MultipartFormDataContent { { file, "file", "x.png" } });
        upload.StatusCode.Should().Be(HttpStatusCode.Created);
        var name = (await JsonAsync(upload)).GetProperty("name").GetString()!;

        var image = await op.Http.GetAsync($"/admin/channels/{alpha}/attachments/{name}");
        image.StatusCode.Should().Be(HttpStatusCode.OK);
        image.Content.Headers.ContentType!.MediaType.Should().Be("image/png");
        (await op.Http.GetAsync($"/admin/channels/{alpha}/attachments/../../x")).StatusCode.Should().Be(HttpStatusCode.NotFound);

        // LIKE wildcards are literal: "50%" matches only Alpha.
        var byName = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/channels?q=50%25"));
        byName.EnumerateArray().Select(c => c.GetProperty("channelId").GetGuid()).Should().Equal(alpha);
        var handle = (await JsonAsync(await SendAsync(owner, HttpMethod.Get, $"/channels/{beta}"))).GetProperty("handle").GetString()!;
        var byHandle = await JsonAsync(await AdminAsync(op, HttpMethod.Get, $"/admin/channels?q={handle.ToLowerInvariant()}"));
        var summary = byHandle.EnumerateArray().Single();
        summary.GetProperty("channelId").GetGuid().Should().Be(beta);
        summary.GetProperty("ownerHandle").GetString().Should().Be(owner.Handle);
        summary.GetProperty("deleted").GetBoolean().Should().BeFalse();
        (await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/channels?limit=1"))).GetArrayLength().Should().Be(1);

        (await DecideAsync(op, new { channelId = alpha, action = "suspend_channel", ground = "terms", rule = "K10",
            explanation = "=HYPERLINK(\"evil\"), \"quoted\"", suspendDays = 2 })).StatusCode.Should().Be(HttpStatusCode.Created);
        (await DecideAsync(op, new { channelId = alpha, action = "restore_channel", explanation = "ok" })).StatusCode.Should().Be(HttpStatusCode.Created);
        (await DecideAsync(op, new { channelId = beta, action = "dismiss", explanation = "fine" })).StatusCode.Should().Be(HttpStatusCode.Created);

        var log = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/decisions"));
        log.EnumerateArray().Select(d => d.GetProperty("action").GetString()).Should().Equal("dismiss", "restore_channel", "suspend_channel");
        var page = await JsonAsync(await AdminAsync(op, HttpMethod.Get,
            $"/admin/decisions?limit=1&before={Uri.EscapeDataString(log[0].GetProperty("createdAt").GetString()!)}"));
        page.EnumerateArray().Select(d => d.GetProperty("action").GetString()).Should().Equal("restore_channel");

        var csv = await op.Http.GetAsync("/admin/decisions?format=csv");
        csv.StatusCode.Should().Be(HttpStatusCode.OK);
        csv.Content.Headers.ContentType!.MediaType.Should().Be("text/csv");
        var lines = (await csv.Content.ReadAsStringAsync()).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        lines[0].Should().Be("decisionId,action,postId,ground,rule,legalGround,explanation,suspendedUntil,basedOnReports,automated,createdAt,operatorAccountId,reportCount,channelId");
        lines.Should().HaveCount(4);
        // Formula injection is neutralised and quotes are doubled.
        lines[3].Should().Contain("\"'=HYPERLINK(\"\"evil\"\"), \"\"quoted\"\"\"");
        lines[3].Should().Contain($"\"{op.AccountId}\"");

        var summaryAfter = await JsonAsync(await AdminAsync(op, HttpMethod.Get, "/admin/summary"));
        summaryAfter.GetProperty("decisionsLast30Days").GetInt32().Should().Be(3);
        summaryAfter.GetProperty("openReports").GetInt32().Should().Be(0);
        summaryAfter.GetProperty("oldestOpenAt").ValueKind.Should().Be(JsonValueKind.Null);
    }
}
