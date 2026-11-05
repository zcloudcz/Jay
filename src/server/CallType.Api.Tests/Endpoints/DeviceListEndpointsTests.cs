using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Endpoints;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class DeviceListEndpointsTests : IntegrationTestBase
{
    private static readonly string Signature = Convert.ToBase64String(new byte[64]);

    private static object Body(Guid primary, int version, params Guid[] companions) => new
    {
        payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            primaryDeviceId = primary,
            version,
            devices = companions.Select(c => new { deviceId = c, identityKey = "a", signingKey = "b", consentSig = "c" })
        }))),
        signature = Signature
    };

    private HttpClient As(string token)
    {
        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>What MessengerHub.LinkConsent records when the companion consents.</summary>
    private void Consent(Guid companion, Guid primary) =>
        Factory.Services.GetRequiredService<IMemoryCache>()
            .Set(DeviceListEndpoints.ConsentKey(companion, primary), true, TimeSpan.FromMinutes(10));

    [Fact]
    public async Task Primary_stores_a_list_and_both_devices_read_the_same_bytes()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        var body = Body(primary.DeviceId, 1, companion.DeviceId);
        Consent(companion.DeviceId, primary.DeviceId);

        var put = await As(primary.Token).PutAsJsonAsync($"/devices/{primary.DeviceId}/device-list", body);
        put.StatusCode.Should().Be(HttpStatusCode.NoContent);

        foreach (var id in new[] { primary.DeviceId, companion.DeviceId })
        {
            var json = await As(companion.Token).GetFromJsonAsync<JsonElement>($"/devices/{id}/device-list");
            json.GetProperty("primaryDeviceId").GetGuid().Should().Be(primary.DeviceId);
            json.GetProperty("version").GetInt32().Should().Be(1);
            json.GetProperty("payload").GetString().Should().Be(
                JsonSerializer.SerializeToElement(body).GetProperty("payload").GetString());
        }
    }

    [Fact]
    public async Task Only_the_primary_itself_may_write_its_list()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        var put = await As(other.Token).PutAsJsonAsync(
            $"/devices/{primary.DeviceId}/device-list", Body(primary.DeviceId, 1, other.DeviceId));
        put.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Version_must_grow()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";
        Consent(companion.DeviceId, primary.DeviceId);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 2, companion.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 2)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        // Removing the companion with a higher version works and frees it.
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 3)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.DeviceListMembers.AnyAsync()).Should().BeFalse();
    }

    [Fact]
    public async Task A_device_belongs_to_at_most_one_identity()
    {
        var a = await RegisterAndAuthenticateAsync();
        var b = await RegisterAndAuthenticateAsync();
        var shared = await RegisterAndAuthenticateAsync();
        // Consents everywhere, so every 409 below comes from the membership rule.
        Consent(shared.DeviceId, a.DeviceId);
        Consent(shared.DeviceId, b.DeviceId);
        Consent(a.DeviceId, b.DeviceId);
        Consent(b.DeviceId, shared.DeviceId);
        (await As(a.Token).PutAsJsonAsync($"/devices/{a.DeviceId}/device-list", Body(a.DeviceId, 1, shared.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        // Already somebody's companion.
        (await As(b.Token).PutAsJsonAsync($"/devices/{b.DeviceId}/device-list", Body(b.DeviceId, 1, shared.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        // A primary with companions cannot become a companion.
        (await As(b.Token).PutAsJsonAsync($"/devices/{b.DeviceId}/device-list", Body(b.DeviceId, 1, a.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        // A companion cannot start a list of its own.
        (await As(shared.Token).PutAsJsonAsync($"/devices/{shared.DeviceId}/device-list", Body(shared.DeviceId, 1, b.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Malformed_oversized_and_unknown_members_are_rejected()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";
        (await client.PutAsJsonAsync(url, new { payload = "!!", signature = Signature }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await client.PutAsJsonAsync(url, Body(Guid.NewGuid(), 1)))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, Guid.NewGuid())))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        var six = new List<Guid>();
        for (var i = 0; i < 6; i++) six.Add((await RegisterAndAuthenticateAsync()).DeviceId);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, six.ToArray())))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task A_new_companion_needs_its_own_consent_but_an_existing_one_does_not()
    {
        // Without this gate anybody could upload a list naming a victim's
        // device: clients reject the list, but the server would route the
        // victim as the uploader's device and the victim could not send.
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";

        var refused = await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, companion.DeviceId));
        refused.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await refused.Content.ReadAsStringAsync()).Should().Contain("device_list_consent_missing");

        Consent(companion.DeviceId, primary.DeviceId);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, companion.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        // The record is consumed, and a device already in the list needs none.
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 2, companion.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
    }

    [Fact]
    public async Task No_list_is_404_and_deleting_devices_cleans_up()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        (await As(primary.Token).GetAsync($"/devices/{primary.DeviceId}/device-list"))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
        Consent(companion.DeviceId, primary.DeviceId);
        await As(primary.Token).PutAsJsonAsync(
            $"/devices/{primary.DeviceId}/device-list", Body(primary.DeviceId, 1, companion.DeviceId));

        // GDPR delete of the companion removes its routing row (FK cascade).
        (await As(companion.Token).DeleteAsync($"/devices/{companion.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            (await db.DeviceListMembers.AnyAsync()).Should().BeFalse();
            (await db.DeviceLists.AnyAsync()).Should().BeTrue();
        }
        // GDPR delete of the primary removes the list.
        (await As(primary.Token).DeleteAsync($"/devices/{primary.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            (await db.DeviceLists.AnyAsync()).Should().BeFalse();
        }
    }

    [Fact]
    public async Task Invalid_shapes_are_400()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";
        string B64(string json) => Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        string Json(Guid p, int v, params Guid[] c) => JsonSerializer.Serialize(new
        {
            primaryDeviceId = p, version = v, devices = c.Select(d => new { deviceId = d })
        });

        // Over 8 KB.
        (await client.PutAsJsonAsync(url, new { payload = Convert.ToBase64String(new byte[8 * 1024 + 1]), signature = Signature }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        // Signature not 64 bytes.
        (await client.PutAsJsonAsync(url, new { payload = B64(Json(primary.DeviceId, 1)), signature = Convert.ToBase64String(new byte[63]) }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        // Duplicate companion, primary listing itself, version 0, version int.MaxValue.
        foreach (var json in new[]
        {
            Json(primary.DeviceId, 1, other.DeviceId, other.DeviceId),
            Json(primary.DeviceId, 1, primary.DeviceId),
            Json(primary.DeviceId, 0),
            Json(primary.DeviceId, int.MaxValue),
        })
            (await client.PutAsJsonAsync(url, new { payload = B64(json), signature = Signature }))
                .StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Concurrent_writes_of_the_same_version_give_one_204_and_one_409()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";
        var results = await Task.WhenAll(
            client.PutAsJsonAsync(url, Body(primary.DeviceId, 1)),
            client.PutAsJsonAsync(url, Body(primary.DeviceId, 1)));
        results.Select(r => r.StatusCode).Should().BeEquivalentTo(
            new[] { HttpStatusCode.NoContent, HttpStatusCode.Conflict });
    }
}
