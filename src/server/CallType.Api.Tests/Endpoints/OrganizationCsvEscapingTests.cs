// ---------------------------------------------------------------------------
// OrganizationCsvEscapingTests.cs — KB6 admin-audit CSV export, DB-free
// ---------------------------------------------------------------------------
// OrganizationEndpoints.ToCsv/EscapeCsv are pure functions — no need for the
// full Testcontainers integration test to check the formula-injection guard.
// ---------------------------------------------------------------------------

using FluentAssertions;
using CallType.Api.Endpoints;
using CallType.Audit.OrgManagement;

namespace CallType.Api.Tests.Endpoints;

public class OrganizationCsvEscapingTests
{
    [Theory]
    [InlineData("=cmd|' /C calc'!A1")]
    [InlineData("+1+1")]
    [InlineData("-1+1")]
    [InlineData("@SUM(A1:A2)")]
    public void ToCsv_prefixes_formula_looking_event_types_with_a_quote(string dangerousEventType)
    {
        var events = new[] { new AdminAuditEventDto(1, Guid.NewGuid(), dangerousEventType, "{}", DateTimeOffset.UtcNow) };

        var csv = OrganizationEndpoints.ToCsv(events);

        csv.Should().Contain($"\"'{dangerousEventType}\"");
    }

    [Fact]
    public void ToCsv_leaves_ordinary_values_unprefixed()
    {
        var events = new[] { new AdminAuditEventDto(1, Guid.NewGuid(), "member_added", "{}", DateTimeOffset.UtcNow) };

        var csv = OrganizationEndpoints.ToCsv(events);

        csv.Should().Contain("\"member_added\"");
    }

    [Fact]
    public void ToCsv_escapes_embedded_quotes()
    {
        var events = new[] { new AdminAuditEventDto(1, Guid.NewGuid(), "member_added", "{\"name\":\"Ac\"\"me\"}", DateTimeOffset.UtcNow) };

        var csv = OrganizationEndpoints.ToCsv(events);

        csv.Should().Contain("\"\"\"");
    }
}
