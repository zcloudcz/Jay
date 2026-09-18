// ---------------------------------------------------------------------------
// BusinessGroupServiceTests.cs — revocation hook (E02)
// ---------------------------------------------------------------------------
// Docker/Testcontainers required (IntegrationTestBase) — not run on a
// machine without Docker; report BLOCKED there, not PASS.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class BusinessGroupServiceTests : IntegrationTestBase
{
    [Fact]
    public async Task Revocation_removes_the_device_only_from_groups_of_that_organization()
    {
        var organizationId = Guid.NewGuid();
        var otherOrganizationId = Guid.NewGuid();
        var device = Guid.NewGuid();
        var businessGroup = Guid.NewGuid();
        var otherOrgGroup = Guid.NewGuid();
        var anonymousGroup = Guid.NewGuid();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.AddRange(
                new Group { GroupId = businessGroup, CreatedBy = device, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId },
                new Group { GroupId = otherOrgGroup, CreatedBy = device, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = otherOrganizationId },
                new Group { GroupId = anonymousGroup, CreatedBy = device, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.AddRange(
                new GroupMember { GroupId = businessGroup, DeviceId = device, Role = "member" },
                new GroupMember { GroupId = otherOrgGroup, DeviceId = device, Role = "member" },
                new GroupMember { GroupId = anonymousGroup, DeviceId = device, Role = "member" });
            await db.SaveChangesAsync();
        }

        using (var scope = Factory.Services.CreateScope())
        {
            var service = scope.ServiceProvider.GetRequiredService<BusinessGroupService>();
            await service.OnEnrollmentRevokedAsync(organizationId, device, CancellationToken.None);
        }

        using var verify = Factory.Services.CreateScope();
        var verifyDb = verify.ServiceProvider.GetRequiredService<AppDbContext>();
        (await verifyDb.GroupMembers.AnyAsync(m => m.GroupId == businessGroup && m.DeviceId == device)).Should().BeFalse();
        (await verifyDb.GroupMembers.AnyAsync(m => m.GroupId == otherOrgGroup && m.DeviceId == device)).Should().BeTrue();
        (await verifyDb.GroupMembers.AnyAsync(m => m.GroupId == anonymousGroup && m.DeviceId == device)).Should().BeTrue();
    }

    [Fact]
    public async Task Revocation_never_removes_the_auditor_membership()
    {
        var organizationId = Guid.NewGuid();
        var auditor = Guid.NewGuid();
        var group = Guid.NewGuid();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = group, CreatedBy = auditor, CreatedAt = DateTimeOffset.UtcNow, OrganizationId = organizationId });
            db.GroupMembers.Add(new GroupMember { GroupId = group, DeviceId = auditor, Role = "auditor" });
            await db.SaveChangesAsync();
        }

        using (var scope = Factory.Services.CreateScope())
        {
            var service = scope.ServiceProvider.GetRequiredService<BusinessGroupService>();
            await service.OnEnrollmentRevokedAsync(organizationId, auditor, CancellationToken.None);
        }

        using var verify = Factory.Services.CreateScope();
        var verifyDb = verify.ServiceProvider.GetRequiredService<AppDbContext>();
        (await verifyDb.GroupMembers.AnyAsync(m => m.GroupId == group && m.DeviceId == auditor)).Should().BeTrue(
            "KB1: the auditor membership is a legal invariant, not something a revocation hook may remove");
    }
}
