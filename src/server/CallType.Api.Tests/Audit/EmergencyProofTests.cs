// ---------------------------------------------------------------------------
// EmergencyProofTests.cs — E07 "Doklad o existenci..." reproducible hash
// ---------------------------------------------------------------------------
// DB-free: EmergencyProof.Build is pure data -> hash. Run with:
//   dotnet test src/server/CallType.Api.Tests --filter "FullyQualifiedName~Audit"
// ---------------------------------------------------------------------------

using CallType.Api.Endpoints;
using CallType.Audit.Emergency;
using FluentAssertions;

namespace CallType.Api.Tests.Audit;

public class EmergencyProofTests
{
    private static EmergencyProofAuditData SampleData() => new(
        OrganizationId: Guid.Parse("11111111-1111-1111-1111-111111111111"),
        OrganizationName: "Acme s.r.o.",
        AuditorDeviceId: Guid.Parse("22222222-2222-2222-2222-222222222222"),
        KitsIssued: 2,
        KitsRevoked: 0,
        LastCompletedDrill: new DrillSummary(1, DateTimeOffset.Parse("2026-09-01T10:00:00Z"),
            DateTimeOffset.Parse("2026-09-01T10:05:00Z"), 3, TimeSpan.FromMinutes(3)),
        ArchiveLastSequence: 42,
        ArchiveLastHash: "deadbeef");

    [Fact]
    public void Same_underlying_data_produces_the_same_hash_regardless_of_when_it_is_generated()
    {
        var data = SampleData();

        var proof1 = EmergencyProof.Build(data, emergencyGroupExists: true, enrolledMemberCount: 5,
            generatedAt: DateTimeOffset.Parse("2026-09-18T08:00:00Z"));
        var proof2 = EmergencyProof.Build(data, emergencyGroupExists: true, enrolledMemberCount: 5,
            generatedAt: DateTimeOffset.Parse("2027-01-01T00:00:00Z")); // different export time

        proof1.SelfHashSha256.Should().Be(proof2.SelfHashSha256);
        proof1.GeneratedAt.Should().NotBe(proof2.GeneratedAt); // sanity: the excluded field really did differ
    }

    [Fact]
    public void Different_underlying_data_produces_a_different_hash()
    {
        var data = SampleData();
        var changed = data with { KitsIssued = 3 };

        var proof1 = EmergencyProof.Build(data, true, 5, DateTimeOffset.UtcNow);
        var proof2 = EmergencyProof.Build(changed, true, 5, DateTimeOffset.UtcNow);

        proof1.SelfHashSha256.Should().NotBe(proof2.SelfHashSha256);
    }

    [Fact]
    public void ToText_escapes_leading_formula_characters_in_the_organization_name()
    {
        var data = SampleData() with { OrganizationName = "=SUM(A1:A9)" };
        var proof = EmergencyProof.Build(data, true, 5, DateTimeOffset.UtcNow);

        proof.ToText().Should().Contain("'=SUM(A1:A9)").And.NotContain("Organizace: =SUM");
    }
}
