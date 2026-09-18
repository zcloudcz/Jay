// ---------------------------------------------------------------------------
// OrganizationTests.cs — Organization aggregate invariants (plan §3, E00)
// ---------------------------------------------------------------------------
// Pure domain tests, no database — the invariants must hold regardless of
// which endpoint (E01) ends up calling into the aggregate.
// ---------------------------------------------------------------------------

using CallType.Audit.Domain;
using FluentAssertions;

namespace CallType.Api.Tests.Audit;

public class OrganizationTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 17, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Create_sets_the_creator_as_the_sole_active_owner()
    {
        var ownerId = Guid.NewGuid();
        var org = Organization.Create(Guid.NewGuid(), "Acme", ownerId, Now);

        org.Members.Should().ContainSingle(m => m.AccountId == ownerId && m.Role == OrgRole.Owner);
    }

    [Fact]
    public void AddMember_rejects_a_second_active_owner()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);

        var act = () => org.AddMember(Guid.NewGuid(), OrgRole.Owner, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("multiple_owners");
    }

    [Fact]
    public void AddMember_rejects_adding_the_same_account_twice()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var accountId = Guid.NewGuid();
        org.AddMember(accountId, OrgRole.Member, Now);

        var act = () => org.AddMember(accountId, OrgRole.OrgAdmin, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("already_member");
    }

    [Fact]
    public void RemoveMember_refuses_to_remove_the_owner()
    {
        var ownerId = Guid.NewGuid();
        var org = Organization.Create(Guid.NewGuid(), "Acme", ownerId, Now);

        var act = () => org.RemoveMember(ownerId, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("last_owner");
    }

    [Fact]
    public void RemoveMember_refuses_to_remove_the_last_org_admin()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var adminId = Guid.NewGuid();
        org.AddMember(adminId, OrgRole.OrgAdmin, Now);

        var act = () => org.RemoveMember(adminId, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("last_admin");
    }

    [Fact]
    public void RemoveMember_allows_removing_an_org_admin_when_another_remains()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var admin1 = Guid.NewGuid();
        var admin2 = Guid.NewGuid();
        org.AddMember(admin1, OrgRole.OrgAdmin, Now);
        org.AddMember(admin2, OrgRole.OrgAdmin, Now);

        org.RemoveMember(admin1, Now);

        org.Members.Single(m => m.AccountId == admin1).RemovedAt.Should().Be(Now);
    }

    [Fact]
    public void RemoveMember_allows_removing_a_plain_member()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var memberId = Guid.NewGuid();
        org.AddMember(memberId, OrgRole.Member, Now);

        org.RemoveMember(memberId, Now);

        org.Members.Single(m => m.AccountId == memberId).RemovedAt.Should().Be(Now);
    }

    [Fact]
    public void RemoveMember_throws_for_an_unknown_or_already_removed_account()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);

        var act = () => org.RemoveMember(Guid.NewGuid(), Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("member_not_found");
    }

    // -----------------------------------------------------------------
    // ChangeMemberRole (E01) — added because Remove+AddMember can't model a
    // role change: the composite key (OrganizationId, AccountId) means the
    // old (soft-removed) row is never deleted, so re-inserting would collide.
    // -----------------------------------------------------------------

    [Fact]
    public void ChangeMemberRole_updates_the_role_of_an_active_member()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var memberId = Guid.NewGuid();
        org.AddMember(memberId, OrgRole.Member, Now);

        org.ChangeMemberRole(memberId, OrgRole.OrgAdmin, Now);

        org.Members.Single(m => m.AccountId == memberId).Role.Should().Be(OrgRole.OrgAdmin);
    }

    [Fact]
    public void ChangeMemberRole_refuses_to_demote_the_last_org_admin()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var adminId = Guid.NewGuid();
        org.AddMember(adminId, OrgRole.OrgAdmin, Now);

        var act = () => org.ChangeMemberRole(adminId, OrgRole.Member, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("last_admin");
    }

    [Fact]
    public void ChangeMemberRole_refuses_to_grant_a_second_owner()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);
        var memberId = Guid.NewGuid();
        org.AddMember(memberId, OrgRole.Member, Now);

        var act = () => org.ChangeMemberRole(memberId, OrgRole.Owner, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("owner_transfer_unsupported");
    }

    [Fact]
    public void ChangeMemberRole_refuses_to_change_the_owners_own_role()
    {
        var ownerId = Guid.NewGuid();
        var org = Organization.Create(Guid.NewGuid(), "Acme", ownerId, Now);

        var act = () => org.ChangeMemberRole(ownerId, OrgRole.OrgAdmin, Now);

        act.Should().Throw<DomainRuleViolation>().Which.Code.Should().Be("last_owner");
    }

    [Fact]
    public void Rename_updates_the_organization_name()
    {
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), Now);

        org.Rename("Acme Corp");

        org.Name.Should().Be("Acme Corp");
    }
}
