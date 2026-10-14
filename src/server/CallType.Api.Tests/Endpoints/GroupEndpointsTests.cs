using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
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

    private HttpClient As(string token)
    {
        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>
    /// Seeded straight into the database, like FanoutHubTests: signatures are
    /// the clients' business, the server only routes by membership.
    /// </summary>
    private async Task LinkAsync(Guid primary, Guid companion)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.DeviceLists.Add(new DeviceList
        {
            PrimaryDeviceId = primary, Version = 1, Payload = [1], Signature = new byte[64],
            UpdatedAt = DateTimeOffset.UtcNow,
            Members = [new DeviceListMember { DeviceId = companion, PrimaryDeviceId = primary }]
        });
        await db.SaveChangesAsync();
    }

    [Fact]
    public async Task A_companion_reads_the_groups_of_its_identity_but_cannot_change_them()
    {
        var phone = await RegisterAndAuthenticateAsync();
        var web = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        var stranger = await RegisterAndAuthenticateAsync();
        await LinkAsync(phone.DeviceId, web.DeviceId);
        var created = await As(phone.Token).PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { other.DeviceId } });
        created.StatusCode.Should().Be(HttpStatusCode.Created);
        var group = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var companion = As(web.Token);
        (await companion.GetAsync($"/groups/{group}")).StatusCode.Should().Be(HttpStatusCode.OK);
        var members = await companion.GetFromJsonAsync<JsonElement>($"/groups/{group}/members");
        members.EnumerateArray().Select(m => m.GetProperty("deviceId").GetGuid())
            .Should().BeEquivalentTo(new[] { phone.DeviceId, other.DeviceId });

        // Membership changes stay with the member device itself (the primary).
        (await companion.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = stranger.DeviceId }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await companion.DeleteAsync($"/groups/{group}/members/{other.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        // A device outside the group still reads nothing.
        (await As(stranger.Token).GetAsync($"/groups/{group}/members"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task A_companion_cannot_create_a_group()
    {
        var phone = await RegisterAndAuthenticateAsync();
        var web = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        await LinkAsync(phone.DeviceId, web.DeviceId);

        var response = await As(web.Token).PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { other.DeviceId } });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("companion_cannot_manage_groups");
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
