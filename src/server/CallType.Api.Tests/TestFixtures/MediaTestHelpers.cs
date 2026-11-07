// ---------------------------------------------------------------------------
// MediaTestHelpers.cs - Shared HTTP helpers for the encrypted media tests
// ---------------------------------------------------------------------------
// Used by MediaEndpointsTests, MediaCleanupServiceTests and
// PrivacyEndpointsTests. Sizes are kept tiny: the smallest legal encrypted
// chunk is 1 MiB + 16 bytes, and most tests need only one short chunk.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;

namespace CallType.Api.Tests.TestFixtures;

public static class MediaTestHelpers
{
    /// <summary>Smallest legal encrypted chunk size (1 MiB plaintext + 16-byte tag).</summary>
    public const int ChunkSize = 1024 * 1024 + 16;

    public sealed record TestDevice(Guid DeviceId, string Token, HttpClient Http);

    /// <summary>Registers a device on <paramref name="factory"/> and returns a client authenticated as it.</summary>
    public static async Task<TestDevice> NewDeviceAsync(WebApplicationFactory<Program> factory)
    {
        var http = factory.CreateClient();
        var reg = await http.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06])
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
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
        return new TestDevice(deviceId, token, http);
    }

    public static Task<HttpResponseMessage> CreateAsync(HttpClient http, long size, int chunkSize = ChunkSize) =>
        http.PostAsJsonAsync("/media", new { size, chunkSize });

    /// <summary>Creates an upload and returns its id (asserting 201).</summary>
    public static async Task<Guid> CreateOkAsync(HttpClient http, long size, int chunkSize = ChunkSize)
    {
        var response = await CreateAsync(http, size, chunkSize);
        response.StatusCode.Should().Be(HttpStatusCode.Created, await response.Content.ReadAsStringAsync());
        return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
    }

    public static Task<HttpResponseMessage> PutChunkAsync(HttpClient http, Guid id, int index, byte[] bytes)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return http.PutAsync($"/media/{id}/chunks/{index}", content);
    }

    /// <summary>Deterministic pseudo-random "ciphertext" of the given length.</summary>
    public static byte[] Bytes(int length, int seed = 1)
    {
        var bytes = new byte[length];
        new Random(seed).NextBytes(bytes);
        return bytes;
    }

    /// <summary>Creates, uploads (in ChunkSize chunks) and completes <paramref name="blob"/>; returns the id.</summary>
    public static async Task<Guid> UploadCompletedAsync(HttpClient http, byte[] blob)
    {
        var id = await CreateOkAsync(http, blob.Length);
        for (int index = 0, offset = 0; offset < blob.Length; index++, offset += ChunkSize)
        {
            var chunk = blob.AsSpan(offset, Math.Min(ChunkSize, blob.Length - offset)).ToArray();
            var put = await PutChunkAsync(http, id, index, chunk);
            put.StatusCode.Should().Be(HttpStatusCode.NoContent, await put.Content.ReadAsStringAsync());
        }
        var complete = await http.PostAsync($"/media/{id}/complete", null);
        complete.StatusCode.Should().Be(HttpStatusCode.OK, await complete.Content.ReadAsStringAsync());
        return id;
    }

    public static async Task<string?> ErrorCodeAsync(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync();
        if (string.IsNullOrEmpty(body)) return null;
        return JsonDocument.Parse(body).RootElement.TryGetProperty("code", out var code) ? code.GetString() : null;
    }
}
