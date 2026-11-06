// ---------------------------------------------------------------------------
// PushRegistrationEndpointsTests.cs - PUT/DELETE push-token, webpush key
// ---------------------------------------------------------------------------
// HTTP contract of docs/superpowers/specs/2026-11-06-notifications.md 1.1
// against the real API and PostgreSQL: self only, per-platform validation
// with error codes, locale storage, DELETE, and GET /push/webpush-key with
// and without configured VAPID keys.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class PushRegistrationEndpointsTests : IntegrationTestBase
{
    private async Task<(string? Token, string? Platform, string? Locale)> StoredAsync(Guid id)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var d = await db.Devices.AsNoTracking().SingleAsync(x => x.DeviceId == id);
        return (d.PushToken, d.PushPlatform, d.PushLocale);
    }

    private static async Task<string?> ErrorCodeAsync(HttpResponseMessage response)
    {
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.TryGetProperty("error", out var e) ? e.GetString() : null;
    }

    [Fact]
    public async Task Webpush_subscription_and_locale_are_stored()
    {
        var (id, _, _) = await RegisterAndAuthenticateAsync();
        var (json, key, _) = PushKeys.NewSubscription();
        using var _k = key;

        var response = await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "webpush", token = json, locale = "cs-CZ" });

        response.StatusCode.Should().Be(HttpStatusCode.NoContent);
        var (token, platform, locale) = await StoredAsync(id);
        platform.Should().Be("webpush");
        locale.Should().Be("cs-CZ");
        JsonDocument.Parse(token!).RootElement.GetProperty("endpoint").GetString()
            .Should().Be("https://push.example.net/push/abc");
    }

    [Theory]
    [InlineData("apns", "not-hex", "invalid_token")]
    [InlineData("apns", "abcd", "invalid_token")]
    [InlineData("webpush", "{\"endpoint\":\"http://push.example.net/x\",\"keys\":{}}", "invalid_token")]
    [InlineData("webpush", "plain-string", "invalid_token")]
    [InlineData("fcm", "", "invalid_token")]
    [InlineData("gcm", "t", "invalid_platform")]
    public async Task Invalid_registration_is_400_with_a_code(string platform, string token, string code)
    {
        var (id, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{id}/push-token", new { platform, token });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ErrorCodeAsync(response)).Should().Be(code);
        (await StoredAsync(id)).Token.Should().BeNull();
    }

    [Fact]
    public async Task Too_long_token_and_bad_locale_are_rejected()
    {
        var (id, _, _) = await RegisterAndAuthenticateAsync();

        var tooLong = await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "fcm", token = new string('a', 2049) });
        var badLocale = await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "fcm", token = "t", locale = "this-is-not-a-locale-at-all" });

        tooLong.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ErrorCodeAsync(tooLong)).Should().Be("invalid_token");
        badLocale.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ErrorCodeAsync(badLocale)).Should().Be("invalid_locale");
    }

    [Fact]
    public async Task Delete_clears_token_platform_and_locale_and_is_self_only()
    {
        var (other, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{other}/push-token",
            new { platform = "fcm", token = "other-token", locale = "en" })).EnsureSuccessStatusCode();
        var (me, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{me}/push-token",
            new { platform = "apns", token = new string('b', 64), locale = "cs" })).EnsureSuccessStatusCode();

        (await Client.DeleteAsync($"/devices/{other}/push-token")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Client.DeleteAsync($"/devices/{me}/push-token")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        // Idempotent: a retried logout still succeeds.
        (await Client.DeleteAsync($"/devices/{me}/push-token")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await StoredAsync(me)).Should().Be(((string?)null, (string?)null, (string?)null));
        (await StoredAsync(other)).Should().Be(("other-token", "fcm", "en"));
    }

    // -----------------------------------------------------------------------
    // Call ringing registration (spec 2026-11-06-call-ringing 1.1)
    // -----------------------------------------------------------------------

    private async Task<(string? Voip, bool RingCalls)> RingAsync(Guid id)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var d = await db.Devices.AsNoTracking().SingleAsync(x => x.DeviceId == id);
        return (d.VoipPushToken, d.PushRingCalls);
    }

    [Fact]
    public async Task Voip_token_is_stored_lowercase_and_deleted_self_only()
    {
        var (other, _, _) = await RegisterAndAuthenticateAsync();
        var (me, _, _) = await RegisterAndAuthenticateAsync();
        var token = new string('A', 32) + new string('b', 32);

        (await Client.PutAsJsonAsync($"/devices/{other}/voip-token", new { token }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Client.DeleteAsync($"/devices/{other}/voip-token")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Client.PutAsJsonAsync($"/devices/{me}/voip-token", new { token }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await RingAsync(me)).Voip.Should().Be(token.ToLowerInvariant());
        (await RingAsync(other)).Voip.Should().BeNull();

        (await Client.DeleteAsync($"/devices/{me}/voip-token")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await Client.DeleteAsync($"/devices/{me}/voip-token")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await RingAsync(me)).Voip.Should().BeNull();
    }

    [Theory]
    [InlineData("not-hex")]
    [InlineData("abcd")]
    [InlineData("")]
    [InlineData(null)]
    public async Task Invalid_voip_token_is_400_invalid_token(string? token)
    {
        var (id, _, _) = await RegisterAndAuthenticateAsync();

        var response = await Client.PutAsJsonAsync($"/devices/{id}/voip-token", new { token });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ErrorCodeAsync(response)).Should().Be("invalid_token");
        (await RingAsync(id)).Voip.Should().BeNull();
    }

    [Fact]
    public async Task Voip_token_requires_authentication()
    {
        using var anonymous = Factory.CreateClient();
        (await anonymous.PutAsJsonAsync($"/devices/{Guid.NewGuid()}/voip-token", new { token = new string('a', 64) }))
            .StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Ring_calls_is_stored_only_for_fcm_and_defaults_to_false()
    {
        var (id, _, _) = await RegisterAndAuthenticateAsync();

        (await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "fcm", token = "t", ringCalls = true })).EnsureSuccessStatusCode();
        (await RingAsync(id)).RingCalls.Should().BeTrue();

        // An old app re-registering without the field turns ringing off again.
        (await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "fcm", token = "t" })).EnsureSuccessStatusCode();
        (await RingAsync(id)).RingCalls.Should().BeFalse();

        (await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "apns", token = new string('c', 64), ringCalls = true })).EnsureSuccessStatusCode();
        (await RingAsync(id)).RingCalls.Should().BeFalse("iOS rings through its VoIP token instead");
    }

    [Fact]
    public async Task Delete_push_token_also_clears_the_ring_registration()
    {
        var (id, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{id}/push-token",
            new { platform = "fcm", token = "t", ringCalls = true })).EnsureSuccessStatusCode();
        (await Client.PutAsJsonAsync($"/devices/{id}/voip-token",
            new { token = new string('d', 64) })).EnsureSuccessStatusCode();

        (await Client.DeleteAsync($"/devices/{id}/push-token")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await RingAsync(id)).Should().Be(((string?)null, false));
        (await StoredAsync(id)).Token.Should().BeNull();
    }

    [Fact]
    public async Task Delete_requires_authentication()
    {
        using var anonymous = Factory.CreateClient();
        (await anonymous.DeleteAsync($"/devices/{Guid.NewGuid()}/push-token"))
            .StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Webpush_key_is_404_when_not_configured()
    {
        using var anonymous = Factory.CreateClient();
        (await anonymous.GetAsync("/push/webpush-key")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Webpush_key_is_served_anonymously_when_configured()
    {
        var (pub, priv) = PushKeys.NewVapidKeys();
        await using var factory = Factory.WithWebHostBuilder(b => b.ConfigureAppConfiguration((_, c) =>
            c.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Push:WebPush:PublicKey"] = pub,
                ["Push:WebPush:PrivateKey"] = priv,
            })));
        using var anonymous = factory.CreateClient();

        var response = await anonymous.GetAsync("/push/webpush-key");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("publicKey").GetString()
            .Should().Be(pub);
    }
}
