// ---------------------------------------------------------------------------
// BotCommandsEndpointsTests.cs - agent messaging contract section 4 (server)
// ---------------------------------------------------------------------------
// Covers PUT/GET /devices/{id}/bot-commands: self-only and bot-only write,
// validation (problem+json error invalid_bot_commands), clear by empty list,
// read by any authenticated device, 404 and 401.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class BotCommandsEndpointsTests : IntegrationTestBase
{
    /// <summary>Registers a device with its own authenticated client, leaving the shared Client anonymous.</summary>
    private async Task<(Guid Id, HttpClient Http)> DeviceAsync(bool isBot = false)
    {
        var reg = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]),
            isBot
        });
        reg.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await reg.Content.ReadFromJsonAsync<JsonElement>();
        var id = Guid.Parse(body.GetProperty("deviceId").GetString()!);
        var tokenResponse = await Client.PostAsJsonAsync("/auth/token",
            new { deviceId = id, deviceSecret = body.GetProperty("deviceSecret").GetString() });
        var token = (await tokenResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
        var http = Factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (id, http);
    }

    private static Task<HttpResponseMessage> PutRawAsync(HttpClient http, Guid id, string json) =>
        http.PutAsync($"/devices/{id}/bot-commands", new StringContent(json, Encoding.UTF8, "application/json"));

    private static async Task<List<(string Command, string Description)>> CommandsOf(HttpResponseMessage response)
    {
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.GetProperty("commands").EnumerateArray()
            .Select(c => (c.GetProperty("command").GetString()!, c.GetProperty("description").GetString()!))
            .ToList();
    }

    private static async Task ShouldBeProblem(HttpResponseMessage response, HttpStatusCode status, string error)
    {
        response.StatusCode.Should().Be(status);
        response.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString().Should().Be(error);
    }

    [Fact]
    public async Task Bot_sets_commands_and_another_device_reads_them()
    {
        var bot = await DeviceAsync(isBot: true);
        var human = await DeviceAsync();

        var put = await PutRawAsync(bot.Http, bot.Id,
            """{"commands":[{"command":"help","description":"  Show help  "},{"command":"start_2","description":"Start"}]}""");

        put.StatusCode.Should().Be(HttpStatusCode.OK);
        // Returned "as stored": description trimmed, order kept.
        (await CommandsOf(put)).Should().Equal(("help", "Show help"), ("start_2", "Start"));

        var get = await human.Http.GetAsync($"/devices/{bot.Id}/bot-commands");
        get.StatusCode.Should().Be(HttpStatusCode.OK);
        (await CommandsOf(get)).Should().Equal(("help", "Show help"), ("start_2", "Start"));
    }

    [Fact]
    public async Task Get_before_any_put_returns_empty_list()
    {
        var bot = await DeviceAsync(isBot: true);
        var human = await DeviceAsync();

        var get = await human.Http.GetAsync($"/devices/{bot.Id}/bot-commands");

        get.StatusCode.Should().Be(HttpStatusCode.OK);
        (await CommandsOf(get)).Should().BeEmpty();
    }

    [Fact]
    public async Task Empty_list_clears_the_commands()
    {
        var bot = await DeviceAsync(isBot: true);
        (await PutRawAsync(bot.Http, bot.Id, """{"commands":[{"command":"help","description":"Help"}]}"""))
            .StatusCode.Should().Be(HttpStatusCode.OK);

        var clear = await PutRawAsync(bot.Http, bot.Id, """{"commands":[]}""");

        clear.StatusCode.Should().Be(HttpStatusCode.OK);
        (await CommandsOf(clear)).Should().BeEmpty();
        (await CommandsOf(await bot.Http.GetAsync($"/devices/{bot.Id}/bot-commands"))).Should().BeEmpty();
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.Devices.Where(d => d.DeviceId == bot.Id).Select(d => d.BotCommandsJson).SingleAsync())
            .Should().BeNull();
    }

    [Fact]
    public async Task Another_device_cannot_set_a_bots_commands()
    {
        var bot = await DeviceAsync(isBot: true);
        var otherBot = await DeviceAsync(isBot: true);

        var response = await PutRawAsync(otherBot.Http, bot.Id, """{"commands":[{"command":"evil","description":"x"}]}""");

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await CommandsOf(await otherBot.Http.GetAsync($"/devices/{bot.Id}/bot-commands"))).Should().BeEmpty();
    }

    [Fact]
    public async Task Non_bot_device_gets_403_not_a_bot()
    {
        var human = await DeviceAsync();

        var response = await PutRawAsync(human.Http, human.Id, """{"commands":[{"command":"help","description":"Help"}]}""");

        await ShouldBeProblem(response, HttpStatusCode.Forbidden, "not_a_bot");
    }

    [Fact]
    public async Task Get_for_non_bot_returns_empty_list()
    {
        var human = await DeviceAsync();
        var other = await DeviceAsync();
        // Even a value smuggled into the column directly is never shown for a
        // human device: the menu is a bot-only feature.
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await db.Devices.Where(d => d.DeviceId == human.Id).ExecuteUpdateAsync(s =>
                s.SetProperty(d => d.BotCommandsJson, """[{"command":"x","description":"y"}]"""));
        }

        var get = await other.Http.GetAsync($"/devices/{human.Id}/bot-commands");

        get.StatusCode.Should().Be(HttpStatusCode.OK);
        (await CommandsOf(get)).Should().BeEmpty();
    }

    [Fact]
    public async Task Get_unknown_device_is_404()
    {
        var caller = await DeviceAsync();

        var get = await caller.Http.GetAsync($"/devices/{Guid.NewGuid()}/bot-commands");

        get.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Unauthenticated_requests_are_401()
    {
        var bot = await DeviceAsync(isBot: true);

        (await Client.GetAsync($"/devices/{bot.Id}/bot-commands")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await PutRawAsync(Client, bot.Id, """{"commands":[]}""")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    public static TheoryData<string> InvalidBodies()
    {
        var data = new TheoryData<string>
        {
            """{}""",
            """{"commands":null}""",
            """{"commands":[null]}""",
            """{"commands":[{"command":"Help","description":"x"}]}""",
            """{"commands":[{"command":"/help","description":"x"}]}""",
            """{"commands":[{"command":"he lp","description":"x"}]}""",
            """{"commands":[{"command":"","description":"x"}]}""",
            """{"commands":[{"description":"x"}]}""",
            $$"""{"commands":[{"command":"{{new string('a', 33)}}","description":"x"}]}""",
            """{"commands":[{"command":"help","description":"a"},{"command":"help","description":"b"}]}""",
            """{"commands":[{"command":"help","description":""}]}""",
            """{"commands":[{"command":"help","description":"   "}]}""",
            """{"commands":[{"command":"help"}]}""",
            $$"""{"commands":[{"command":"help","description":"{{new string('d', 101)}}"}]}""",
        };
        var tooMany = Enumerable.Range(0, 51).Select(i => new { command = $"c{i}", description = "d" });
        data.Add(JsonSerializer.Serialize(new { commands = tooMany }));
        return data;
    }

    [Theory]
    [MemberData(nameof(InvalidBodies))]
    public async Task Invalid_commands_are_a_400_problem(string json)
    {
        var bot = await DeviceAsync(isBot: true);

        var response = await PutRawAsync(bot.Http, bot.Id, json);

        await ShouldBeProblem(response, HttpStatusCode.BadRequest, "invalid_bot_commands");
    }

    [Fact]
    public async Task Limits_are_inclusive()
    {
        var bot = await DeviceAsync(isBot: true);
        var fifty = Enumerable.Range(0, 50).Select(i => new { command = $"c{i}", description = "d" }).ToList();
        fifty[0] = new { command = new string('a', 32), description = "  " + new string('d', 100) + "  " };

        var response = await bot.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-commands", new { commands = fifty });

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var stored = await CommandsOf(response);
        stored.Should().HaveCount(50);
        stored[0].Should().Be((new string('a', 32), new string('d', 100)));
    }

    // -----------------------------------------------------------------------
    // PUT/GET /devices/{id}/bot-policy (spec 2026-11-09-bot-access A1)
    // -----------------------------------------------------------------------

    private static async Task<string> HandleOf((Guid Id, HttpClient Http) device) =>
        (await (await device.Http.GetAsync($"/devices/{device.Id}/profile")).Content.ReadFromJsonAsync<JsonElement>())
            .GetProperty("userHandle").GetString()!;

    [Fact]
    public async Task Bot_policy_defaults_to_open_and_round_trips_owners_as_handles()
    {
        var bot = await DeviceAsync(isBot: true);
        var owner = await DeviceAsync();
        var handle = await HandleOf(owner);

        var initial = await bot.Http.GetFromJsonAsync<JsonElement>($"/devices/{bot.Id}/bot-policy");
        initial.GetProperty("mode").GetString().Should().Be("open");

        // Lower case and duplicates are normalized.
        var put = await bot.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-policy",
            new { mode = "OWNERS", owners = new[] { handle.ToLowerInvariant(), handle } });
        put.StatusCode.Should().Be(HttpStatusCode.OK);
        var read = await bot.Http.GetFromJsonAsync<JsonElement>($"/devices/{bot.Id}/bot-policy");
        read.GetProperty("mode").GetString().Should().Be("owners");
        read.GetProperty("owners").EnumerateArray().Select(o => o.GetString()).Should().Equal(handle);

        // Back to open clears the owners.
        (await bot.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-policy", new { mode = "open", owners = new[] { handle } }))
            .StatusCode.Should().Be(HttpStatusCode.OK);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var row = await db.Devices.AsNoTracking().SingleAsync(d => d.DeviceId == bot.Id);
        row.BotInboundMode.Should().Be("open");
        row.BotInboundOwnerIds.Should().BeNull();
    }

    [Fact]
    public async Task Bot_policy_is_self_only_bot_only_and_validated()
    {
        var bot = await DeviceAsync(isBot: true);
        var human = await DeviceAsync();
        var handle = await HandleOf(human);

        // Another device may neither write nor READ it (the owner list must
        // not leak, spec A2 "no oracle").
        (await human.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-policy", new { mode = "open" }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await human.Http.GetAsync($"/devices/{bot.Id}/bot-policy")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        // A human device cannot set one for itself.
        await ShouldBeProblem(await human.Http.PutAsJsonAsync($"/devices/{human.Id}/bot-policy",
            new { mode = "owners", owners = new[] { handle } }), HttpStatusCode.Forbidden, "not_a_bot");

        await ShouldBeProblem(await bot.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-policy",
            new { mode = "everyone" }), HttpStatusCode.BadRequest, "invalid_bot_policy");
        await ShouldBeProblem(await bot.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-policy",
            new { mode = "owners", owners = new[] { "CT-ZZZZ-ZZZZ" } }), HttpStatusCode.BadRequest, "unknown_owner");
        var eleven = Enumerable.Range(0, 11).Select(i => $"CT-AAAA-{i:D4}").ToArray();
        await ShouldBeProblem(await bot.Http.PutAsJsonAsync($"/devices/{bot.Id}/bot-policy",
            new { mode = "owners", owners = eleven }), HttpStatusCode.BadRequest, "invalid_bot_policy");
    }
}

