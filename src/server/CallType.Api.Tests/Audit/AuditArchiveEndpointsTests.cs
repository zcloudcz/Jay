// ---------------------------------------------------------------------------
// AuditArchiveEndpointsTests.cs — E03-lite: metadata archive write API
// ---------------------------------------------------------------------------
// Covers the KB3 write-path guarantees: only the org's auditor device may
// write, a retried write is idempotent (never appends twice), the hash chain
// is continuous, malformed hashes are rejected, and the admin count endpoint
// enforces OrgAdmin+.
//
// BLOCKED on this machine: Testcontainers needs Docker, which is not
// installed here (see BusinessModeIntegrationTests for the same note). This
// file compiles and is believed correct but has not been executed.
// ---------------------------------------------------------------------------

using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Audit;

public class AuditArchiveEndpointsTests : IntegrationTestBase
{
    private async Task<Guid> SeedOrganizationAsync(Guid? auditorDeviceId)
    {
        var orgId = Guid.NewGuid();
        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var org = Organization.Create(orgId, "Acme", Guid.NewGuid(), DateTimeOffset.UtcNow);
        org.AuditorDeviceId = auditorDeviceId;
        auditDb.Organizations.Add(org);
        await auditDb.SaveChangesAsync();
        return orgId;
    }

    private static object ValidRecordBody(Guid groupId, Guid senderDeviceId, string? messageId = null, string? hash = null) => new
    {
        groupId,
        messageId = messageId ?? Guid.NewGuid().ToString(),
        senderDeviceId,
        sentAt = DateTimeOffset.UtcNow,
        kind = "text",
        sizeBytes = 42,
        contentHash = hash ?? Convert.ToHexString(new byte[32]) // 64 hex chars
    };

    [Fact]
    public async Task Non_auditor_device_gets_403()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(Guid.NewGuid()); // a different device is the auditor

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records",
            ValidRecordBody(Guid.NewGuid(), deviceId));

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Repeat_post_for_same_message_is_idempotent()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);
        var body = ValidRecordBody(Guid.NewGuid(), deviceId);

        var first = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", body);
        var second = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", body);

        first.StatusCode.Should().Be(HttpStatusCode.OK);
        second.StatusCode.Should().Be(HttpStatusCode.OK);

        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        (await auditDb.AuditRecords.CountAsync(r => r.OrganizationId == orgId)).Should().Be(1);
    }

    [Fact]
    public async Task Hash_chain_is_continuous_across_records()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);

        for (var i = 0; i < 5; i++)
        {
            var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records",
                ValidRecordBody(Guid.NewGuid(), deviceId));
            response.StatusCode.Should().Be(HttpStatusCode.OK);
        }

        using var scope = Factory.Services.CreateScope();
        var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
        var records = await auditDb.AuditRecords.Where(r => r.OrganizationId == orgId)
            .OrderBy(r => r.Sequence).ToListAsync();

        records.Should().HaveCount(5);
        records[0].Sequence.Should().Be(1);
        records[0].PrevHash.Should().BeEquivalentTo(CallType.Audit.Application.HashChain.Genesis);
        for (var i = 1; i < records.Count; i++)
        {
            records[i].Sequence.Should().Be(records[i - 1].Sequence + 1);
            records[i].PrevHash.Should().BeEquivalentTo(records[i - 1].Hash);
        }
    }

    [Fact]
    public async Task Malformed_content_hash_returns_422()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records",
            ValidRecordBody(Guid.NewGuid(), deviceId, hash: "not-hex"));

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task Count_endpoint_requires_org_admin_role()
    {
        var (auditorDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(auditorDeviceId);
        await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", ValidRecordBody(Guid.NewGuid(), auditorDeviceId));

        // The auditor device itself has no org-admin account link -> forbidden.
        var forbidden = await Client.GetAsync($"/orgs/{orgId}/audit/records/count");
        forbidden.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Link a fresh device to an OrgAdmin account and try again.
        using (var scope = Factory.Services.CreateScope())
        {
            var appDb = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var accountId = Guid.NewGuid();
            appDb.Accounts.Add(new Account { AccountId = accountId, Email = "admin@acme.test", CreatedAt = DateTimeOffset.UtcNow });
            appDb.AccountDevices.Add(new AccountDevice { AccountId = accountId, DeviceId = auditorDeviceId, LinkedAt = DateTimeOffset.UtcNow });
            await appDb.SaveChangesAsync();

            var org = await auditDb.Organizations.SingleAsync(o => o.OrganizationId == orgId);
            org.AddMember(accountId, OrgRole.OrgAdmin, DateTimeOffset.UtcNow);
            await auditDb.SaveChangesAsync();
        }

        var ok = await Client.GetAsync($"/orgs/{orgId}/audit/records/count");
        ok.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await ok.Content.ReadFromJsonAsync<CallType.Api.Endpoints.AuditRecordCountDto>();
        body!.Count.Should().Be(1);
        body.LastSequence.Should().Be(1);
        body.LastHash.Should().NotBeNullOrEmpty();
    }

    // W2-E: the count endpoint's liveness fields (lastArchivedAt / pendingForAuditor
    // / oldestPendingAt), added so an admin can tell a dead archiver from a quiet one.
    [Fact]
    public async Task Count_endpoint_reports_last_archived_at_and_pending_queue()
    {
        var (auditorDeviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(auditorDeviceId);

        var beforeArchive = DateTimeOffset.UtcNow;
        var archived = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", ValidRecordBody(Guid.NewGuid(), auditorDeviceId));
        archived.StatusCode.Should().Be(HttpStatusCode.OK);

        // Give the auditor device an OrgAdmin-linked account so GET .../count is allowed.
        using (var scope = Factory.Services.CreateScope())
        {
            var appDb = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var auditDb = scope.ServiceProvider.GetRequiredService<AuditDbContext>();
            var accountId = Guid.NewGuid();
            appDb.Accounts.Add(new Account { AccountId = accountId, Email = "admin2@acme.test", CreatedAt = DateTimeOffset.UtcNow });
            appDb.AccountDevices.Add(new AccountDevice { AccountId = accountId, DeviceId = auditorDeviceId, LinkedAt = DateTimeOffset.UtcNow });

            // Two queued messages addressed to the auditor device — one still
            // waiting for the archiver to pick up (the "pending" case), one
            // already acknowledged (must NOT count as pending).
            var senderId = Guid.NewGuid();
            var older = new QueuedMessage
            {
                RecipientId = auditorDeviceId, SenderId = senderId,
                CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-5), ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
            };
            var newer = new QueuedMessage
            {
                RecipientId = auditorDeviceId, SenderId = senderId,
                CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-1), ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
            };
            var acked = new QueuedMessage
            {
                RecipientId = auditorDeviceId, SenderId = senderId,
                CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-10), ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
                AcknowledgedAt = DateTimeOffset.UtcNow,
            };
            appDb.QueuedMessages.AddRange(older, newer, acked);

            var org = await auditDb.Organizations.SingleAsync(o => o.OrganizationId == orgId);
            org.AddMember(accountId, OrgRole.OrgAdmin, DateTimeOffset.UtcNow);

            await appDb.SaveChangesAsync();
            await auditDb.SaveChangesAsync();
        }

        var response = await Client.GetAsync($"/orgs/{orgId}/audit/records/count");
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<CallType.Api.Endpoints.AuditRecordCountDto>();

        body!.LastArchivedAt.Should().NotBeNull();
        body.LastArchivedAt!.Value.Should().BeOnOrAfter(beforeArchive);
        body.PendingForAuditor.Should().Be(2); // "older" and "newer" — "acked" excluded
        body.OldestPendingAt.Should().NotBeNull();
    }

    // -------------------------------------------------------------------
    // H1 — call metadata is kept readable (details), bound into the chain
    // via ContentHash == SHA-256(details). See docs/superpowers/plans/
    // 2026-09-18-business-mode-contracts.md, "H1" for the exact rules.
    // -------------------------------------------------------------------

    private static string ValidCallDetails(string outcome = "completed", string? endedAt = "2026-09-18T12:05:00Z") =>
        JsonSerializer.Serialize(new
        {
            callId = Guid.NewGuid().ToString(),
            role = "caller",
            peerDeviceId = Guid.NewGuid().ToString(),
            startedAt = "2026-09-18T12:00:00Z",
            endedAt,
            media = "audio",
            outcome
        });

    private static string HashOf(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private static object CallMetadataBody(Guid groupId, Guid senderDeviceId, string details) => new
    {
        groupId,
        messageId = Guid.NewGuid().ToString(),
        senderDeviceId,
        sentAt = DateTimeOffset.UtcNow,
        kind = "call-metadata",
        sizeBytes = Encoding.UTF8.GetByteCount(details),
        contentHash = HashOf(details),
        details
    };

    [Fact]
    public async Task Call_metadata_with_valid_details_is_stored_and_returned_readable()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);
        var details = ValidCallDetails();

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records",
            CallMetadataBody(Guid.NewGuid(), deviceId, details));

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var dto = await response.Content.ReadFromJsonAsync<CallType.Api.Endpoints.AuditRecordDto>();
        dto!.Details.Should().Be(details);
    }

    [Fact]
    public async Task Details_on_a_text_record_is_rejected()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);
        var withDetails = new
        {
            groupId = Guid.NewGuid(),
            messageId = Guid.NewGuid().ToString(),
            senderDeviceId = deviceId,
            sentAt = DateTimeOffset.UtcNow,
            kind = "text",
            sizeBytes = 42,
            contentHash = Convert.ToHexString(new byte[32]),
            details = "not allowed here"
        };

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", withDetails);

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("details_not_allowed");
    }

    [Fact]
    public async Task Call_metadata_without_details_is_rejected()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", new
        {
            groupId = Guid.NewGuid(),
            messageId = Guid.NewGuid().ToString(),
            senderDeviceId = deviceId,
            sentAt = DateTimeOffset.UtcNow,
            kind = "call-metadata",
            sizeBytes = 10,
            contentHash = Convert.ToHexString(new byte[32])
        });

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("invalid_call_details");
    }

    [Fact]
    public async Task Call_metadata_with_malformed_details_is_rejected()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);
        // Missing "outcome" — same strict-key-set rule the archiver enforces.
        var badDetails = JsonSerializer.Serialize(new
        {
            callId = Guid.NewGuid().ToString(),
            role = "caller",
            peerDeviceId = Guid.NewGuid().ToString(),
            startedAt = "2026-09-18T12:00:00Z",
            endedAt = "2026-09-18T12:05:00Z",
            media = "audio"
        });

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records",
            CallMetadataBody(Guid.NewGuid(), deviceId, badDetails));

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("invalid_call_details");
    }

    [Fact]
    public async Task Call_metadata_details_hash_mismatch_is_rejected()
    {
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var orgId = await SeedOrganizationAsync(deviceId);
        var details = ValidCallDetails();
        var mismatched = new
        {
            groupId = Guid.NewGuid(),
            messageId = Guid.NewGuid().ToString(),
            senderDeviceId = deviceId,
            sentAt = DateTimeOffset.UtcNow,
            kind = "call-metadata",
            sizeBytes = Encoding.UTF8.GetByteCount(details),
            contentHash = Convert.ToHexString(new byte[32]), // deliberately wrong
            details
        };

        var response = await Client.PostAsJsonAsync($"/orgs/{orgId}/audit/records", mismatched);

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("details_hash_mismatch");
    }
}
