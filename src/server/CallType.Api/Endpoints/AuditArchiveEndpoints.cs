// ---------------------------------------------------------------------------
// AuditArchiveEndpoints.cs — E03: metadata-level archive write API (KB3)
// ---------------------------------------------------------------------------
// Two endpoints:
//   POST /orgs/{orgId}/audit/records         — the archiver (jay_archiver)
//     appends one AuditRecord per archived group message.
//   GET  /orgs/{orgId}/audit/records/count   — a cheap "is the archive
//     alive" signal for admins (E05/E07 poll this rather than reading the
//     hash chain themselves).
//
// Both are no-ops (503) when business mode is disabled — see
// BusinessModeOptions. Neither ever touches message plaintext: the request
// body carries only metadata plus a client-computed SHA-256 content hash
// (KB3 — the archiver decrypts in memory and discards the plaintext before
// this call is made).
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Audit.Application;
using CallType.Audit.Domain;
using CallType.Audit.Infrastructure;

namespace CallType.Api.Endpoints;

public static partial class AuditArchiveEndpoints
{
    public static WebApplication MapAuditArchiveEndpoints(this WebApplication app)
    {
        app.MapPost("/orgs/{orgId:guid}/audit/records", PostRecord).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/orgs/{orgId:guid}/audit/records/count", GetCount).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static Guid Caller(ClaimsPrincipal user) => Guid.TryParse(
        user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub"), out var id) ? id : Guid.Empty;

    // Hex-encoded SHA-256: exactly 64 lowercase-or-uppercase hex digits.
    [GeneratedRegex("^[0-9a-fA-F]{64}$")]
    private static partial Regex ContentHashPattern();

    private static readonly string[] AllowedKinds = ["text", "attachment", "call"];

    // A row that has never been superseded — a handful of retries is plenty
    // for a single-writer-per-organization archiver; anything beyond that
    // means real contention and should surface as an error rather than loop.
    private const int MaxSequenceRetries = 5;

    private static async Task<IResult> PostRecord(Guid orgId, ArchiveRecordRequest request,
        ClaimsPrincipal user, BusinessModeOptions businessMode, AuditDbContext auditDb, CancellationToken ct)
    {
        if (!businessMode.Enabled) return Results.Json(new { error = "business_mode_disabled" }, statusCode: StatusCodes.Status503ServiceUnavailable);

        var caller = Caller(user);
        if (caller == Guid.Empty) return Results.Unauthorized();

        if (!AllowedKinds.Contains(request.Kind))
            return Results.UnprocessableEntity(new { error = "kind must be one of: text, attachment, call." });
        if (request.SizeBytes < 0)
            return Results.UnprocessableEntity(new { error = "sizeBytes must not be negative." });
        if (!ContentHashPattern().IsMatch(request.ContentHash))
            return Results.UnprocessableEntity(new { error = "contentHash must be 64 hex characters (SHA-256)." });

        var org = await auditDb.Organizations.FindAsync([orgId], ct);
        if (org is null) return Results.NotFound();

        // KB2/KB3: only the organization's designated auditor device may write
        // to its archive — this is what makes "the auditor archived it" mean
        // something instead of any authenticated device being able to forge history.
        if (org.AuditorDeviceId != caller) return Results.Forbid();

        // Idempotent on MessageId (globally unique per SendReliableGroupMessage) —
        // a lost ACK causes the archiver to retry the same message, and that must
        // not append a second chain entry (see AuditRecord's unique index).
        var existing = await auditDb.AuditRecords
            .SingleOrDefaultAsync(r => r.OrganizationId == orgId && r.MessageId == request.MessageId, ct);
        if (existing is not null) return Results.Ok(ToDto(existing));

        var contentHash = Convert.FromHexString(request.ContentHash);
        var now = DateTimeOffset.UtcNow;

        for (var attempt = 1; ; attempt++)
        {
            var last = await auditDb.AuditRecords
                .Where(r => r.OrganizationId == orgId)
                .OrderByDescending(r => r.Sequence)
                .FirstOrDefaultAsync(ct);
            var prevHash = last?.Hash ?? HashChain.Genesis;
            var sequence = (last?.Sequence ?? 0) + 1;

            var record = new AuditRecord(orgId, request.GroupId, request.MessageId, request.SenderDeviceId,
                request.SentAt, now, request.Kind, request.SizeBytes, contentHash, ciphertextForArchive: null,
                sequence, prevHash, ComputeHash(orgId, request, contentHash, now, sequence, prevHash));

            auditDb.AuditRecords.Add(record);
            try
            {
                await auditDb.SaveChangesAsync(ct);
                return Results.Ok(ToDto(record));
            }
            catch (DbUpdateException) when (attempt < MaxSequenceRetries)
            {
                // Unique index on (OrganizationId, Sequence) — the app role has no
                // UPDATE/SELECT-FOR-UPDATE privilege (KB3), so a concurrent writer
                // is detected here (constraint violation) rather than prevented by
                // a row lock. Detach the failed entry and retry with a fresh Sequence.
                auditDb.Entry(record).State = EntityState.Detached;

                // A concurrent write to the SAME MessageId means we lost the race
                // for idempotence too — fetch what the other writer produced.
                var raced = await auditDb.AuditRecords
                    .SingleOrDefaultAsync(r => r.OrganizationId == orgId && r.MessageId == request.MessageId, ct);
                if (raced is not null) return Results.Ok(ToDto(raced));
            }
        }
    }

    // Field order is fixed and must match what any future offline verifier
    // (tools/audit-verify, E03's own deliverable) reproduces — see HashChain.
    private static byte[] ComputeHash(Guid orgId, ArchiveRecordRequest request, byte[] contentHash,
        DateTimeOffset archivedAt, long sequence, byte[] prevHash) => HashChain.ComputeHash(prevHash,
        HashChain.Canonicalize([
            orgId.ToString(), request.GroupId.ToString(), request.MessageId.ToString(),
            request.SenderDeviceId.ToString(), request.SentAt.ToString("O"), archivedAt.ToString("O"),
            request.Kind, request.SizeBytes.ToString(), Convert.ToHexString(contentHash), sequence.ToString()
        ]));

    private static AuditRecordDto ToDto(AuditRecord r) => new(r.OrganizationId, r.GroupId, r.MessageId,
        r.SenderDeviceId, r.SentAt, r.ArchivedAt, r.Kind, r.SizeBytes, Convert.ToHexString(r.ContentHash),
        r.Sequence, Convert.ToHexString(r.Hash));

    private static async Task<IResult> GetCount(Guid orgId, ClaimsPrincipal user, BusinessModeOptions businessMode,
        AuditDbContext auditDb, AppDbContext appDb, CancellationToken ct)
    {
        if (!businessMode.Enabled) return Results.Json(new { error = "business_mode_disabled" }, statusCode: StatusCodes.Status503ServiceUnavailable);

        var callerDevice = Caller(user);
        if (callerDevice == Guid.Empty) return Results.Unauthorized();

        if (!await auditDb.Organizations.AnyAsync(o => o.OrganizationId == orgId, ct)) return Results.NotFound();

        // The JWT identifies a device, but org governance (KB6) is per-account —
        // resolve the caller's linked account(s) and check for an active
        // OrgAdmin-or-above membership. A device with no linked account (e.g. an
        // anonymous member device) simply has no admin role anywhere.
        var accountIds = await appDb.AccountDevices.Where(ad => ad.DeviceId == callerDevice)
            .Select(ad => ad.AccountId).ToListAsync(ct);
        var isAdmin = accountIds.Count > 0 && await auditDb.OrgMembers.AnyAsync(m =>
            m.OrganizationId == orgId && accountIds.Contains(m.AccountId) && m.RemovedAt == null &&
            (m.Role == OrgRole.Owner || m.Role == OrgRole.OrgAdmin), ct);
        if (!isAdmin) return Results.Forbid();

        var last = await auditDb.AuditRecords.Where(r => r.OrganizationId == orgId)
            .OrderByDescending(r => r.Sequence).FirstOrDefaultAsync(ct);
        var count = await auditDb.AuditRecords.CountAsync(r => r.OrganizationId == orgId, ct);
        return Results.Ok(new AuditRecordCountDto(count, last?.Sequence ?? 0,
            last is null ? null : Convert.ToHexString(last.Hash)));
    }
}

public record ArchiveRecordRequest(Guid GroupId, Guid MessageId, Guid SenderDeviceId, DateTimeOffset SentAt,
    string Kind, long SizeBytes, string ContentHash);

public record AuditRecordDto(Guid OrganizationId, Guid GroupId, Guid MessageId, Guid SenderDeviceId,
    DateTimeOffset SentAt, DateTimeOffset ArchivedAt, string Kind, long SizeBytes, string ContentHash,
    long Sequence, string Hash);

public record AuditRecordCountDto(int Count, long LastSequence, string? LastHash);
