// ---------------------------------------------------------------------------
// GroupEndpointsTests.cs — Integration tests for group endpoints
// ---------------------------------------------------------------------------
// Tests group creation, membership management, and edge cases against a real
// PostgreSQL instance via Testcontainers. Verifies that the creator gets admin
// role, duplicate members are rejected, and removal works correctly.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using ZMessanger.Api.Tests.TestFixtures;

namespace ZMessanger.Api.Tests.Endpoints;

public class GroupEndpointsTests : IntegrationTestBase
{
    // Reusable key material for device registration helper.
    private static readonly string ValidIdentityKey = Convert.ToBase64String([0x01, 0x02, 0x03]);
    private static readonly string ValidSignedPreKey = Convert.ToBase64String([0x04, 0x05, 0x06]);

    /// <summary>
    /// Helper: registers a device and returns its deviceId.
    /// </summary>
    private async Task<Guid> RegisterDeviceAsync()
    {
        var response = await Client.PostAsJsonAsync("/devices", new
        {
            identityKey = ValidIdentityKey,
            signedPreKey = ValidSignedPreKey
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return Guid.Parse(body.GetProperty("deviceId").GetString()!);
    }

    /// <summary>
    /// Helper: creates a group with the given device as creator and returns the groupId.
    /// </summary>
    private async Task<Guid> CreateGroupAsync(Guid createdBy, string? nameEncrypted = null)
    {
        var response = await Client.PostAsJsonAsync("/groups", new
        {
            createdBy,
            nameEncrypted
        });
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return Guid.Parse(body.GetProperty("groupId").GetString()!);
    }

    // -----------------------------------------------------------------------
    // POST /groups — Create group
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Create_group_adds_creator_as_admin()
    {
        // Arrange
        var deviceId = await RegisterDeviceAsync();

        // Act — create a group
        var createResponse = await Client.PostAsJsonAsync("/groups", new
        {
            createdBy = deviceId,
            nameEncrypted = Convert.ToBase64String([0xAA, 0xBB])
        });

        // Assert — group created
        createResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var createBody = await createResponse.Content.ReadFromJsonAsync<JsonElement>();
        var groupId = Guid.Parse(createBody.GetProperty("groupId").GetString()!);

        // Verify the creator is an admin member
        var membersResponse = await Client.GetAsync($"/groups/{groupId}/members");
        membersResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var members = await membersResponse.Content.ReadFromJsonAsync<JsonElement>();
        members.GetArrayLength().Should().Be(1, "only the creator should be a member");

        var creator = members[0];
        creator.GetProperty("deviceId").GetString().Should().Be(deviceId.ToString());
        creator.GetProperty("role").GetString().Should().Be("admin",
            "the group creator must be assigned the admin role");
    }

    [Fact]
    public async Task Create_group_with_nonexistent_device_returns_400()
    {
        var response = await Client.PostAsJsonAsync("/groups", new
        {
            createdBy = Guid.NewGuid()
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Create_group_without_name_succeeds()
    {
        // Arrange — unnamed groups are valid (ad-hoc chats)
        var deviceId = await RegisterDeviceAsync();

        // Act — omit nameEncrypted
        var response = await Client.PostAsJsonAsync("/groups", new
        {
            createdBy = deviceId
        });

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Created);
    }

    // -----------------------------------------------------------------------
    // PUT /groups/{groupId}/members — Add member
    // DELETE /groups/{groupId}/members/{deviceId} — Remove member
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Add_and_remove_member_works()
    {
        // Arrange
        var creatorDevice = await RegisterDeviceAsync();
        var memberDevice = await RegisterDeviceAsync();
        var groupId = await CreateGroupAsync(creatorDevice);

        // Act — add a member
        var addResponse = await Client.PutAsJsonAsync(
            $"/groups/{groupId}/members",
            new { deviceId = memberDevice });

        // Assert — member added
        addResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        // Verify the group now has 2 members
        var membersResponse = await Client.GetAsync($"/groups/{groupId}/members");
        var members = await membersResponse.Content.ReadFromJsonAsync<JsonElement>();
        members.GetArrayLength().Should().Be(2);

        // The new member should have "member" role (not "admin")
        var newMember = members.EnumerateArray()
            .First(m => m.GetProperty("deviceId").GetString() == memberDevice.ToString());
        newMember.GetProperty("role").GetString().Should().Be("member");

        // Act — remove the member
        var removeResponse = await Client.DeleteAsync(
            $"/groups/{groupId}/members/{memberDevice}");

        // Assert — member removed
        removeResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        // Verify the group is back to 1 member (just the creator)
        var finalMembersResponse = await Client.GetAsync($"/groups/{groupId}/members");
        var finalMembers = await finalMembersResponse.Content.ReadFromJsonAsync<JsonElement>();
        finalMembers.GetArrayLength().Should().Be(1);
    }

    [Fact]
    public async Task Add_duplicate_member_returns_409_conflict()
    {
        // Arrange
        var creatorDevice = await RegisterDeviceAsync();
        var memberDevice = await RegisterDeviceAsync();
        var groupId = await CreateGroupAsync(creatorDevice);

        // Add once — should succeed
        var firstAdd = await Client.PutAsJsonAsync(
            $"/groups/{groupId}/members",
            new { deviceId = memberDevice });
        firstAdd.StatusCode.Should().Be(HttpStatusCode.OK);

        // Act — add the same device again
        var secondAdd = await Client.PutAsJsonAsync(
            $"/groups/{groupId}/members",
            new { deviceId = memberDevice });

        // Assert
        secondAdd.StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Add_member_to_nonexistent_group_returns_404()
    {
        var deviceId = await RegisterDeviceAsync();

        var response = await Client.PutAsJsonAsync(
            $"/groups/{Guid.NewGuid()}/members",
            new { deviceId });

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Remove_nonexistent_member_returns_404()
    {
        var creatorDevice = await RegisterDeviceAsync();
        var groupId = await CreateGroupAsync(creatorDevice);

        var response = await Client.DeleteAsync(
            $"/groups/{groupId}/members/{Guid.NewGuid()}");

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    // -----------------------------------------------------------------------
    // GET /groups/{groupId}/members — List members
    // -----------------------------------------------------------------------

    [Fact]
    public async Task List_members_returns_all_members_with_roles()
    {
        // Arrange — create a group with creator + 2 additional members
        var creatorDevice = await RegisterDeviceAsync();
        var member1 = await RegisterDeviceAsync();
        var member2 = await RegisterDeviceAsync();
        var groupId = await CreateGroupAsync(creatorDevice);

        await Client.PutAsJsonAsync($"/groups/{groupId}/members", new { deviceId = member1 });
        await Client.PutAsJsonAsync($"/groups/{groupId}/members", new { deviceId = member2 });

        // Act
        var response = await Client.GetAsync($"/groups/{groupId}/members");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var members = await response.Content.ReadFromJsonAsync<JsonElement>();
        members.GetArrayLength().Should().Be(3);

        // Verify roles: 1 admin (creator), 2 members
        var roles = members.EnumerateArray()
            .Select(m => m.GetProperty("role").GetString())
            .ToList();

        roles.Should().ContainSingle(r => r == "admin");
        roles.Count(r => r == "member").Should().Be(2);

        // Every member should have a joinedAt timestamp
        foreach (var member in members.EnumerateArray())
        {
            member.GetProperty("joinedAt").GetString().Should().NotBeNullOrEmpty();
        }
    }

    [Fact]
    public async Task List_members_for_nonexistent_group_returns_404()
    {
        var response = await Client.GetAsync($"/groups/{Guid.NewGuid()}/members");

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
