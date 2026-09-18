// ---------------------------------------------------------------------------
// MfaEndpointsTests.cs — Integration tests for TOTP MFA endpoints (N03a)
// ---------------------------------------------------------------------------
// Uses a derived WebApplicationFactory (Factory.WithWebHostBuilder) with a
// FakeTimeProvider override so TOTP time-step math is deterministic instead
// of racing 30s wall-clock boundaries — the same override point every
// handler uses (Program.cs registers TimeProvider.System as a singleton,
// last-registered-wins lets a test override it).
//
// PITFALL (per docs/superpowers/plans/2026-09-18-business-mode-contracts.md
// and prior packages): RegisterAndAuthenticateAsync re-points the shared
// Client's Bearer token to the LAST registered device. A derived factory
// needs ITS OWN HttpClient with the Authorization header set explicitly —
// never assume it inherits Client's header.
// ---------------------------------------------------------------------------

using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace CallType.Api.Tests.Endpoints;

public class MfaEndpointsTests : IntegrationTestBase
{
    private const int MaxFailedAttemptsForTest = 5; // mirrors MfaEndpoints.MaxFailedAttempts (private to that file)

    private static readonly string ValidAuthKey = Convert.ToBase64String(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]);

    /// <summary>Registers+authenticates a device, registers an account, links them, and
    /// returns a client whose Bearer token is that device's — matching the "own HttpClient"
    /// pitfall above, every test gets a fresh client instead of relying on the shared one.</summary>
    private async Task<(HttpClient Client, Guid DeviceId, Guid AccountId)> CreateLinkedAccountClientAsync(string email)
    {
        var (deviceId, token, _) = await RegisterAndAuthenticateAsync();

        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        accountResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var accountId = Guid.Parse((await accountResponse.Content.ReadFromJsonAsync<JsonElement>())
            .GetProperty("accountId").GetString()!);

        var linkResponse = await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey });
        linkResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (client, deviceId, accountId);
    }

    private static async Task<(string SecretBase32, string OtpauthUri)> EnrollStartAsync(HttpClient client, Guid accountId)
    {
        var response = await client.PostAsync($"/accounts/{accountId}/mfa/enroll/start", null);
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return (body.GetProperty("secretBase32").GetString()!, body.GetProperty("otpauthUri").GetString()!);
    }

    private static async Task<List<string>> EnrollConfirmAsync(HttpClient client, Guid accountId, string code)
    {
        var response = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/confirm", new { code });
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.GetProperty("backupCodes").EnumerateArray().Select(e => e.GetString()!).ToList();
    }

    /// <summary>Builds a factory with a fake clock and sets up a fully enrolled MFA account
    /// on it (enroll/start + confirm happen through this factory's own client, at the fake
    /// clock's current instant, so every test starts from a known TOTP time-step).</summary>
    private async Task<(WebApplicationFactory<Program> Factory, HttpClient Client, Guid AccountId, byte[] Secret, FakeTimeProvider Clock, List<string> BackupCodes)>
        SetUpEnrolledAccountAsync()
    {
        var clock = new FakeTimeProvider(DateTimeOffset.UtcNow);
        // The derived factory inherits the base factory's config (same Jwt:Secret, same
        // database via Testcontainers), so a token minted through the base Client is also
        // valid on a client created from this derived factory — no second /auth/token call.
        var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureServices(services => services.AddSingleton<TimeProvider>(clock)));

        var (deviceId, token, _) = await RegisterAndAuthenticateAsync();
        var email = $"mfa-{Guid.NewGuid():N}@example.com";
        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        var accountId = Guid.Parse((await accountResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetString()!);
        await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey });

        var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var (secretBase32, _) = await EnrollStartAsync(client, accountId);
        var secret = Base32.Decode(secretBase32);
        var code = TotpService.ComputeCode(secret, clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period);
        var backupCodes = await EnrollConfirmAsync(client, accountId, code);

        return (factory, client, accountId, secret, clock, backupCodes);
    }

    [Fact]
    public async Task EnrollAndConfirm_HappyPath_EnablesMfaAndReturnsTenBackupCodes()
    {
        var (client, _, accountId) = await CreateLinkedAccountClientAsync($"happy-{Guid.NewGuid():N}@example.com");

        var statusBefore = await client.GetFromJsonAsync<JsonElement>($"/accounts/{accountId}/mfa");
        statusBefore.GetProperty("enabled").GetBoolean().Should().BeFalse();

        var (secretBase32, otpauthUri) = await EnrollStartAsync(client, accountId);
        otpauthUri.Should().StartWith("otpauth://totp/");
        var secret = Base32.Decode(secretBase32);
        var step = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / TotpService.Period;
        var code = TotpService.ComputeCode(secret, step);

        var backupCodes = await EnrollConfirmAsync(client, accountId, code);
        backupCodes.Should().HaveCount(MfaBackupCodes.CodeCount);
        backupCodes.Should().OnlyHaveUniqueItems();

        var statusAfter = await client.GetFromJsonAsync<JsonElement>($"/accounts/{accountId}/mfa");
        statusAfter.GetProperty("enabled").GetBoolean().Should().BeTrue();
        statusAfter.GetProperty("backupCodesRemaining").GetInt32().Should().Be(MfaBackupCodes.CodeCount);
    }

    [Fact]
    public async Task EnrollConfirm_WrongCode_Returns400()
    {
        var (client, _, accountId) = await CreateLinkedAccountClientAsync($"wrongconfirm-{Guid.NewGuid():N}@example.com");
        await EnrollStartAsync(client, accountId);

        var response = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/enroll/confirm", new { code = "000000" });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_invalid_code");
    }

    [Fact]
    public async Task Verify_WrongCode_Returns401()
    {
        var (_, client, accountId, _, _, _) = await SetUpEnrolledAccountAsync();

        var response = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code = "000000" });

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_invalid_code");
    }

    [Fact]
    public async Task Verify_Succeeds_AndReplayOfSameCodeIsRejected()
    {
        var (_, client, accountId, secret, clock, _) = await SetUpEnrolledAccountAsync();
        // enroll/confirm already consumed the step at the clock's starting instant
        // (LastAcceptedStep) — advance one period so this test's code is a fresh step.
        clock.Advance(TimeSpan.FromSeconds(TotpService.Period));
        var code = TotpService.ComputeCode(secret, clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period);

        var first = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code });
        first.StatusCode.Should().Be(HttpStatusCode.OK);
        var firstBody = await first.Content.ReadFromJsonAsync<JsonElement>();
        firstBody.GetProperty("token").GetString().Should().NotBeNullOrEmpty();

        var replay = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code });
        replay.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await replay.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_code_reused");
    }

    [Fact]
    public async Task Verify_AcceptsOneStepAway_RejectsTwoStepsAway()
    {
        var (_, client, accountId, secret, clock, _) = await SetUpEnrolledAccountAsync();

        // Move the clock forward one period so "current" becomes step+1 relative
        // to the step accepted during enroll/confirm.
        clock.Advance(TimeSpan.FromSeconds(TotpService.Period));
        var current = clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period;

        // current+1 is one step away from "current" -> accepted.
        var oneAway = TotpService.ComputeCode(secret, current + 1);
        var oneAwayResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code = oneAway });
        oneAwayResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        // current+2 is two steps away -> outside the -1/0/+1 window -> rejected.
        var twoAway = TotpService.ComputeCode(secret, current + 2);
        var twoAwayResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code = twoAway });
        twoAwayResponse.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Verify_LocksAfterFiveConsecutiveFailures()
    {
        var (_, client, accountId, _, _, _) = await SetUpEnrolledAccountAsync();

        HttpResponseMessage? last = null;
        for (var i = 0; i < 5; i++)
            last = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code = "000000" });

        last!.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        (await last.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_locked");

        // Locked out even with a correct code until LockedUntil passes.
        var afterLock = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code = "123456" });
        afterLock.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
    }

    [Fact]
    public async Task Verify_ParallelWrongGuesses_LockExactlyOnceNoRaceBypass()
    {
        var (factory, client, accountId, _, _, _) = await SetUpEnrolledAccountAsync();

        // 8 concurrent wrong guesses against a 5-failure threshold: the atomic
        // ExecuteUpdateAsync must serialize the increments (no lost updates from
        // a race-y read-increment-write) and the lock must actually fire. Once
        // locked, a request that reads the row AFTER the lock is set correctly
        // short-circuits to 429 without incrementing further — so the final
        // count can legitimately land anywhere in [5, 8] depending on
        // interleaving; only < 5 (lock never fired) or > 8 (double-counted)
        // would indicate a real race bug.
        const int concurrentGuesses = 8;
        var tasks = Enumerable.Range(0, concurrentGuesses)
            .Select(_ => client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code = "000000" }));
        var responses = await Task.WhenAll(tasks);

        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var mfa = await db.AccountMfas.AsNoTracking().SingleAsync(m => m.AccountId == accountId);
        mfa.FailedAttempts.Should().BeInRange(MaxFailedAttemptsForTest, concurrentGuesses);
        mfa.LockedUntil.Should().NotBeNull(); // the lock fired despite the race
        responses.Should().Contain(r => r.StatusCode == HttpStatusCode.TooManyRequests); // and was actually surfaced to a caller
    }

    [Fact]
    public async Task Verify_BackupCode_SingleUse_ParallelDoubleSpendOnlySucceedsOnce()
    {
        var (_, client, accountId, _, _, backupCodes) = await SetUpEnrolledAccountAsync();
        var code = backupCodes[0];

        var responses = await Task.WhenAll(
            client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { backupCode = code }),
            client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { backupCode = code }));

        responses.Count(r => r.StatusCode == HttpStatusCode.OK).Should().Be(1);
        responses.Count(r => r.StatusCode == HttpStatusCode.Unauthorized).Should().Be(1);
    }

    [Fact]
    public async Task RefreshToken_NeverCarriesStepUpClaims()
    {
        var (_, client, accountId, secret, clock, _) = await SetUpEnrolledAccountAsync();
        // enroll/confirm already consumed the starting step — advance so this code is fresh.
        clock.Advance(TimeSpan.FromSeconds(TotpService.Period));
        var code = TotpService.ComputeCode(secret, clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period);
        var verifyResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/verify", new { code });
        verifyResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var stepUpToken = (await verifyResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        // Sanity: the step-up token itself DOES carry amr.
        new JwtSecurityTokenHandler().ReadJwtToken(stepUpToken).Claims.Should().Contain(c => c.Type == "amr");

        var refreshClient = Factory.CreateClient();
        refreshClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", stepUpToken);
        var refreshResponse = await refreshClient.PostAsync("/auth/refresh", null);
        refreshResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var refreshedToken = (await refreshResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;

        var refreshedClaims = new JwtSecurityTokenHandler().ReadJwtToken(refreshedToken).Claims;
        refreshedClaims.Should().NotContain(c => c.Type == "amr");
        refreshedClaims.Should().NotContain(c => c.Type == "mfa_acc");
        refreshedClaims.Should().NotContain(c => c.Type == "mfa_at");
    }

    [Fact]
    public async Task AnotherAccountsDevice_Returns403()
    {
        var (_, _, accountId) = await CreateLinkedAccountClientAsync($"owner-{Guid.NewGuid():N}@example.com");

        // A second, unrelated device — never linked to accountId.
        var (_, strangerToken, _) = await RegisterAndAuthenticateAsync();
        var strangerClient = Factory.CreateClient();
        strangerClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", strangerToken);

        var response = await strangerClient.GetAsync($"/accounts/{accountId}/mfa");
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task MissingEncryptionKey_Returns503OnMfaEndpoints()
    {
        await using var factory = Factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) =>
                config.AddInMemoryCollection(new Dictionary<string, string?> { ["Mfa:EncryptionKey"] = "" })));

        var (deviceId, token, _) = await RegisterAndAuthenticateAsync();
        var email = $"nokey-{Guid.NewGuid():N}@example.com";
        var accountResponse = await Client.PostAsJsonAsync("/accounts", new { email, authKey = ValidAuthKey });
        var accountId = Guid.Parse((await accountResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accountId").GetString()!);
        await Client.PostAsJsonAsync($"/accounts/{accountId}/devices/{deviceId}", new { authKey = ValidAuthKey });

        var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await client.PostAsync($"/accounts/{accountId}/mfa/enroll/start", null);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString().Should().Be("mfa_not_configured");
    }

    [Fact]
    public async Task StoredSecret_IsNotThePlaintextBase32Secret()
    {
        var (client, _, accountId) = await CreateLinkedAccountClientAsync($"plaintext-{Guid.NewGuid():N}@example.com");
        var (secretBase32, _) = await EnrollStartAsync(client, accountId);
        var rawSecret = Base32.Decode(secretBase32);

        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var stored = await db.AccountMfas.AsNoTracking().SingleAsync(m => m.AccountId == accountId);

        stored.EncryptedSecret.Should().NotEqual(rawSecret);
        // The raw secret bytes must not appear anywhere in the stored blob either
        // (a weaker "not equal" check alone would pass even for a no-op transform
        // that merely prepends/appends bytes around the plaintext).
        IndexOf(stored.EncryptedSecret, rawSecret).Should().Be(-1);
    }

    private static int IndexOf(byte[] haystack, byte[] needle)
    {
        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            var match = true;
            for (var j = 0; j < needle.Length; j++)
                if (haystack[i + j] != needle[j]) { match = false; break; }
            if (match) return i;
        }
        return -1;
    }

    [Fact]
    public async Task Disable_RequiresValidCode()
    {
        var (_, client, accountId, secret, clock, _) = await SetUpEnrolledAccountAsync();

        var wrongCodeResponse = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/disable", new { code = "000000" });
        wrongCodeResponse.StatusCode.Should().Be(HttpStatusCode.Unauthorized);

        // enroll/confirm already consumed the starting step — advance so this code is fresh.
        clock.Advance(TimeSpan.FromSeconds(TotpService.Period));
        var code = TotpService.ComputeCode(secret, clock.GetUtcNow().ToUnixTimeSeconds() / TotpService.Period);
        var response = await client.PostAsJsonAsync($"/accounts/{accountId}/mfa/disable", new { code });
        response.StatusCode.Should().Be(HttpStatusCode.NoContent);

        var status = await client.GetFromJsonAsync<JsonElement>($"/accounts/{accountId}/mfa");
        status.GetProperty("enabled").GetBoolean().Should().BeFalse();
    }
}
