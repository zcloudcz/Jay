using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class GroupEndpointsTests : IntegrationTestBase
{
    private async Task<Guid> CreateGroupAsync(params Guid[] members)
    {
        var response = await Client.PostAsJsonAsync("/groups", new { memberDeviceIds = members });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();
    }

    [Fact]
    public async Task Creation_uses_authenticated_creator_and_adds_initial_members()
    {
        var (memberId, _, _) = await RegisterAndAuthenticateAsync();
        var (creatorId, _, _) = await RegisterAndAuthenticateAsync();
        var group = await CreateGroupAsync(memberId, memberId);
        var members = await Client.GetFromJsonAsync<JsonElement>($"/groups/{group}/members");
        members.GetArrayLength().Should().Be(2);
        members.EnumerateArray().Single(m => m.GetProperty("role").GetString() == "admin")
            .GetProperty("deviceId").GetGuid().Should().Be(creatorId);
    }

    [Fact]
    public async Task Member_list_includes_public_profile_of_each_member()
    {
        // A bot registers anonymously, exactly like the real bots do.
        var botReg = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = Convert.ToBase64String([0x01, 0x02, 0x03]),
            signedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]),
            isBot = true
        });
        botReg.StatusCode.Should().Be(HttpStatusCode.Created);
        var botBody = await botReg.Content.ReadFromJsonAsync<JsonElement>();
        var botId = Guid.Parse(botBody.GetProperty("deviceId").GetString()!);
        var botHandle = botBody.GetProperty("userHandle").GetString()!;

        // A named member: only the device itself may set its display name.
        var (namedId, _, namedHandle) = await RegisterAndAuthenticateAsync();
        (await Client.PutAsJsonAsync($"/devices/{namedId}/profile", new { displayName = "Alice" }))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        // The creator (admin) has no display name and is not a bot.
        var (creatorId, _, creatorHandle) = await RegisterAndAuthenticateAsync();
        var group = await CreateGroupAsync(namedId, botId);

        var members = (await Client.GetFromJsonAsync<JsonElement>($"/groups/{group}/members"))
            .EnumerateArray().ToDictionary(m => m.GetProperty("deviceId").GetGuid());
        members.Count.Should().Be(3);

        members[namedId].GetProperty("userHandle").GetString().Should().Be(namedHandle);
        members[namedId].GetProperty("displayName").GetString().Should().Be("Alice");
        members[namedId].GetProperty("isBot").GetBoolean().Should().BeFalse();

        members[botId].GetProperty("userHandle").GetString().Should().Be(botHandle);
        members[botId].GetProperty("displayName").ValueKind.Should().Be(JsonValueKind.Null);
        members[botId].GetProperty("isBot").GetBoolean().Should().BeTrue();

        members[creatorId].GetProperty("userHandle").GetString().Should().Be(creatorHandle);
        members[creatorId].GetProperty("displayName").ValueKind.Should().Be(JsonValueKind.Null);
        members[creatorId].GetProperty("isBot").GetBoolean().Should().BeFalse();

        // Pre-existing fields are unchanged.
        members[creatorId].GetProperty("role").GetString().Should().Be("admin");
        members[namedId].GetProperty("role").GetString().Should().Be("member");
        members.Values.Select(m => m.GetProperty("joinedAt").GetDateTimeOffset()).Should().HaveCount(3);
    }

    [Fact]
    public async Task Unknown_initial_member_rejects_creation()
    {
        await RegisterAndAuthenticateAsync();
        var response = await Client.PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { Guid.NewGuid() } });
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Outsider_cannot_read_or_mutate_membership()
    {
        await RegisterAndAuthenticateAsync();
        var group = await CreateGroupAsync();
        var (outsider, _, _) = await RegisterAndAuthenticateAsync();
        (await Client.GetAsync($"/groups/{group}/members")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Client.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = outsider }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Client.DeleteAsync($"/groups/{group}/members/{outsider}"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Ordinary_member_can_read_but_cannot_add_members()
    {
        var (member, token, _) = await RegisterAndAuthenticateAsync();
        await RegisterAndAuthenticateAsync();
        var group = await CreateGroupAsync(member);
        Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        (await Client.GetAsync($"/groups/{group}/members")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await Client.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = Guid.NewGuid() }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Admin_can_add_and_remove_members_but_not_last_admin()
    {
        var (member, _, _) = await RegisterAndAuthenticateAsync();
        var (admin, _, _) = await RegisterAndAuthenticateAsync();
        var group = await CreateGroupAsync();
        (await Client.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = member })).StatusCode.Should().Be(HttpStatusCode.OK);
        (await Client.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = member })).StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await Client.DeleteAsync($"/groups/{group}/members/{member}")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await Client.DeleteAsync($"/groups/{group}/members/{admin}")).StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Missing_group_returns_not_found()
    {
        var (device, _, _) = await RegisterAndAuthenticateAsync();
        var group = Guid.NewGuid();
        (await Client.GetAsync($"/groups/{group}/members")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await Client.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = device })).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
