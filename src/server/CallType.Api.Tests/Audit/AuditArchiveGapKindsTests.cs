// ---------------------------------------------------------------------------
// AuditArchiveGapKindsTests.cs — archive kinds added in gap closure X0
// ---------------------------------------------------------------------------
// edit | delete | reaction (M §4.2 X0-M-2: details {"ref","bodyHash"}),
// group-event (no details) and other (K2: details {"type"}). Every kind with
// details binds them into the chain via ContentHash == SHA-256(UTF8(details)).
// Real PostgreSQL for both databases (IntegrationTestBase); several cases per
// test because each test pays for its own containers.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Endpoints;
using CallType.Api.Tests.TestFixtures;
using CallType.Audit.Application;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Tests.Audit;

public class AuditArchiveGapKindsTests : IntegrationTestBase
{
    private static string HashOf(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private static string RefDetails(Guid target, string? bodyHash) =>
        JsonSerializer.Serialize(new { @ref = target.ToString(), bodyHash });

    private async Task<(Guid AuditorId, Guid OrgId)> SeedAuditorAsync()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var org = Organization.Create(Guid.NewGuid(), "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
        org.AuditorDeviceId = deviceId;
        auditDb.Organizations.Add(org);
        await auditDb.SaveChangesAsync();
        return (deviceId, org.OrganizationId);
    }

    private Task<HttpResponseMessage> PostAsync(Guid orgId, Guid sender, string kind, string? details,
        string? contentHash = null, Guid? messageId = null) =>
        Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", new
        {
            groupId = Guid.NewGuid(),
            messageId = messageId ?? Guid.NewGuid(),
            senderDeviceId = sender,
            sentAt = DateTimeOffset.UtcNow,
            kind,
            sizeBytes = 0,
            contentHash = contentHash ?? (details is null ? Convert.ToHexString(new byte[32]) : HashOf(details)),
            details
        });

    private static async Task<string?> ErrorOf(HttpResponseMessage response) =>
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString();

    [Fact]
    public async Task Every_new_kind_is_accepted_stored_with_details_and_chained()
    {
        var (auditor, orgId) = await SeedAuditorAsync();
        var target = Guid.NewGuid();
        var cases = new (string Kind, string? Details)[]
        {
            ("edit", RefDetails(target, HashOf("corrected text"))),
            ("reaction", RefDetails(target, HashOf("\U0001F44D"))),
            ("delete", RefDetails(target, null)),
            ("group-event", null),
            ("other", """{"type":"poll"}"""),
        };

        foreach (var (kind, details) in cases)
        {
            var response = await PostAsync(orgId, auditor, kind, details);
            response.StatusCode.Should().Be(HttpStatusCode.OK, $"kind {kind}: {await response.Content.ReadAsStringAsync()}");
            var dto = await response.Content.ReadFromJsonAsync<AuditRecordDto>();
            dto!.Kind.Should().Be(kind);
            dto.Details.Should().Be(details);
        }

        // One continuous chain across old and new kinds.
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var records = await auditDb.AuditRecords.Where(r => r.OrganizationId == orgId).OrderBy(r => r.Sequence).ToListAsync();
        records.Should().HaveCount(cases.Length);
        records[0].PrevHash.Should().BeEquivalentTo(HashChain.Genesis);
        for (var i = 1; i < records.Count; i++)
        {
            records[i].Sequence.Should().Be(records[i - 1].Sequence + 1);
            records[i].PrevHash.Should().BeEquivalentTo(records[i - 1].Hash);
        }
    }

    [Fact]
    public async Task Malformed_ref_details_are_rejected_as_invalid_ref_details()
    {
        var (auditor, orgId) = await SeedAuditorAsync();
        var target = Guid.NewGuid();
        var hash = HashOf("x");
        var bad = new (string Kind, string? Details)[]
        {
            ("edit", null),                                                            // required
            ("edit", RefDetails(target, null)),                                        // edit needs a bodyHash
            ("reaction", RefDetails(target, "abc")),                                   // not 64 hex
            ("delete", RefDetails(target, hash)),                                      // delete: bodyHash must be null
            ("edit", JsonSerializer.Serialize(new { @ref = "not-a-uuid", bodyHash = hash })),
            ("edit", JsonSerializer.Serialize(new { @ref = target.ToString("N"), bodyHash = hash })), // canonical form only
            ("edit", JsonSerializer.Serialize(new { @ref = target.ToString(), bodyHash = hash, text = "leak" })), // extra key
            ("delete", JsonSerializer.Serialize(new { @ref = target.ToString() })),    // missing key
            ("reaction", "[1,2]"),
            ("edit", "{not json"),
            ("edit", JsonSerializer.Serialize(new { @ref = target.ToString(), bodyHash = hash, pad = new string('x', 300) })),
        };

        foreach (var (kind, details) in bad)
        {
            var response = await PostAsync(orgId, auditor, kind, details);
            response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, $"{kind} {details}");
            (await ErrorOf(response)).Should().Be("invalid_ref_details", $"{kind} {details}");
        }

        using var scope = Factory.Services.CreateScope();
        (await scope.ServiceProvider.GetRequiredService<AuditDbContext>().AuditRecords
            .CountAsync(r => r.OrganizationId == orgId)).Should().Be(0, "nothing may be appended for a rejected record");
    }

    [Fact]
    public async Task Details_hash_mismatch_group_event_details_and_bad_other_are_rejected()
    {
        var (auditor, orgId) = await SeedAuditorAsync();
        var target = Guid.NewGuid();

        var mismatch = await PostAsync(orgId, auditor, "edit", RefDetails(target, HashOf("t")),
            contentHash: Convert.ToHexString(new byte[32]));
        mismatch.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await ErrorOf(mismatch)).Should().Be("details_hash_mismatch");

        var otherMismatch = await PostAsync(orgId, auditor, "other", """{"type":"poll"}""",
            contentHash: Convert.ToHexString(new byte[32]));
        (await ErrorOf(otherMismatch)).Should().Be("details_hash_mismatch");

        var groupEventWithDetails = await PostAsync(orgId, auditor, "group-event", """{"type":"rename"}""");
        groupEventWithDetails.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await ErrorOf(groupEventWithDetails)).Should().Be("details_not_allowed");

        foreach (var details in new string?[]
                 {
                     null,
                     """{"type":""}""",
                     $$"""{"type":"{{new string('a', 33)}}"}""",
                     """{"type":"poll","extra":1}""",
                     """{"kind":"poll"}""",
                     """{"type":7}""",
                     """{"type":"a\u0007b"}""",
                 })
        {
            var response = await PostAsync(orgId, auditor, "other", details);
            response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, details ?? "null");
            (await ErrorOf(response)).Should().Be("invalid_other_details", details ?? "null");
        }

        // The longest legal type (32 chars) passes.
        var longest = $$"""{"type":"{{new string('a', 32)}}"}""";
        (await PostAsync(orgId, auditor, "other", longest)).StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task New_kinds_are_idempotent_on_message_id()
    {
        var (auditor, orgId) = await SeedAuditorAsync();
        var messageId = Guid.NewGuid();
        var details = RefDetails(Guid.NewGuid(), HashOf("v2"));

        var first = await PostAsync(orgId, auditor, "edit", details, messageId: messageId);
        var second = await PostAsync(orgId, auditor, "edit", details, messageId: messageId);

        first.StatusCode.Should().Be(HttpStatusCode.OK);
        second.StatusCode.Should().Be(HttpStatusCode.OK);
        (await second.Content.ReadFromJsonAsync<AuditRecordDto>())!.Sequence
            .Should().Be((await first.Content.ReadFromJsonAsync<AuditRecordDto>())!.Sequence);
        using var scope = Factory.Services.CreateScope();
        (await scope.ServiceProvider.GetRequiredService<AuditDbContext>().AuditRecords
            .CountAsync(r => r.OrganizationId == orgId)).Should().Be(1);
    }

    [Fact]
    public async Task Unknown_kind_error_lists_every_allowed_kind()
    {
        var (auditor, orgId) = await SeedAuditorAsync();

        var response = await PostAsync(orgId, auditor, "sticker", null);

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        var error = await ErrorOf(response);
        foreach (var kind in new[] { "text", "attachment", "call", "call-metadata", "edit", "delete", "reaction", "group-event", "other" })
            error.Should().Contain(kind);
    }
}
