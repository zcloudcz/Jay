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
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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

    // Gap closure X0 added edit/delete/reaction (M §4.2 X0-M-2), group-event
    // (G's group-update) and other (K2: content types the archiver does not
    // understand — recorded instead of acked silently, which would leave a
    // hole in the chain, or never acked, which would stall the organization
    // on auditor_unavailable after 24 h). AuditRecord.Kind is varchar(20), so
    // no Audit DB migration is needed; the longest kind is 13 chars.
    private static readonly string[] AllowedKinds =
        ["text", "attachment", "call", "call-metadata", "edit", "delete", "reaction", "group-event", "other"];

    // Kinds whose details point at an earlier message: {"ref","bodyHash"}.
    private static readonly string[] RefDetailsKinds = ["edit", "delete", "reaction"];
    private static readonly string[] RefDetailsKeys = ["ref", "bodyHash"];
    private const int RefDetailsMaxLength = 256;

    // "other": {"type": "<wire type>"} only — the type name is the one thing
    // an auditor learns about content the archiver could not interpret. K2
    // caps the whole details string at 64 chars, the type itself at 32.
    private const int OtherDetailsMaxLength = 64;
    private const int OtherTypeMaxLength = 32;

    // H1: the exact shape the archiver's group_message_source.dart validates
    // before hashing — kept identical on both sides so "well-formed" means
    // the same thing whether the check runs client-side or here.
    private static readonly string[] CallDetailsKeys =
        ["callId", "role", "peerDeviceId", "startedAt", "endedAt", "media", "outcome"];
    private static readonly string[] CallDetailsRoles = ["caller", "callee"];
    private static readonly string[] CallDetailsMedia = ["audio", "video"];
    private static readonly string[] CallDetailsOutcomes = ["completed", "missed", "rejected", "failed", "unavailable"];
    private const int CallDetailsMaxLength = 1024;

    // A row that has never been superseded — a handful of retries is plenty
    // for a single-writer-per-organization archiver; anything beyond that
    // means real contention and should surface as an error rather than loop.
    private const int MaxSequenceRetries = 5;

    private static async Task<IResult> PostRecord(Guid orgId, ArchiveRecordRequest request,
        ClaimsPrincipal user, BusinessModeOptions businessMode, HttpContext http, CancellationToken ct)
    {
        if (!businessMode.Enabled) return Results.Json(new { error = "business_mode_disabled" }, statusCode: StatusCodes.Status503ServiceUnavailable);

        // AuditDbContext is registered ONLY when business mode is on. Taking it
        // as a handler parameter makes minimal-API parameter inference fail at
        // startup ("Failure to infer one or more parameters") and takes the whole
        // API down for anonymous-only deployments — so resolve it lazily here.
        var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();

        var caller = Caller(user);
        if (caller == Guid.Empty) return Results.Unauthorized();

        // Built from AllowedKinds so the message can never drift from the
        // whitelist again (it listed only three kinds after call-metadata).
        if (!AllowedKinds.Contains(request.Kind))
            return Results.UnprocessableEntity(new { error = $"kind must be one of: {string.Join(", ", AllowedKinds)}." });
        if (request.SizeBytes < 0)
            return Results.UnprocessableEntity(new { error = "sizeBytes must not be negative." });
        if (!ContentHashPattern().IsMatch(request.ContentHash))
            return Results.UnprocessableEntity(new { error = "contentHash must be 64 hex characters (SHA-256)." });

        // H1: details is the one place clear-text leaves the metadata archive
        // level, so it is locked to the kinds that need it, each with an exact
        // shape — never a side door for storing message content. The new
        // edit/delete/reaction/other shapes carry only ids, hashes and a type
        // name: no text, no emoji.
        string? detailsError = request.Kind switch
        {
            "call-metadata" => request.Details is not null && IsWellFormedCallDetails(request.Details)
                ? null : "invalid_call_details",
            "edit" or "delete" or "reaction" => request.Details is not null && IsWellFormedRefDetails(request.Kind, request.Details)
                ? null : "invalid_ref_details",
            "other" => request.Details is not null && IsWellFormedOtherDetails(request.Details)
                ? null : "invalid_other_details",
            // text, attachment, call, group-event: no details at all.
            _ => request.Details is null ? null : "details_not_allowed",
        };
        if (detailsError is not null)
            return Results.UnprocessableEntity(new { error = detailsError });

        if (request.Details is not null)
        {
            // Binds the clear-text details into the existing hash chain without
            // changing how hashes are computed: ContentHash must be exactly
            // SHA-256 of the bytes actually stored, so a tampered/mismatched
            // details string is caught here instead of silently diverging from
            // what the chain claims to cover. Same rule for every kind with details.
            var detailsHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(request.Details)));
            if (!string.Equals(detailsHash, request.ContentHash, StringComparison.OrdinalIgnoreCase))
                return Results.UnprocessableEntity(new { error = "details_hash_mismatch" });
        }

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
                sequence, prevHash, ComputeHash(orgId, request, contentHash, now, sequence, prevHash),
                request.Details);

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
        r.Sequence, Convert.ToHexString(r.Hash), r.DetailsJson);

    // Mirrors the archiver's own validation (group_message_source.dart) so a
    // "well-formed" call event means the same thing on both sides. Rejecting
    // this here — not just trusting the client-computed contentHash — matters
    // because details is clear text an auditor reads directly: garbage in is
    // garbage an admin sees, hash or no hash.
    private static bool IsWellFormedCallDetails(string details)
    {
        if (details.Length > CallDetailsMaxLength) return false;
        JsonElement root;
        try
        {
            root = JsonDocument.Parse(details).RootElement;
        }
        catch (JsonException)
        {
            return false;
        }
        if (root.ValueKind != JsonValueKind.Object) return false;

        var keys = new List<string>();
        foreach (var prop in root.EnumerateObject()) keys.Add(prop.Name);
        if (keys.Count != CallDetailsKeys.Length || !CallDetailsKeys.All(keys.Contains)) return false;

        if (root.GetProperty("callId").ValueKind != JsonValueKind.String) return false;
        if (!CallDetailsRoles.Contains(root.GetProperty("role").GetString())) return false;
        if (root.GetProperty("peerDeviceId").ValueKind != JsonValueKind.String) return false;
        if (!CallDetailsMedia.Contains(root.GetProperty("media").GetString())) return false;
        if (!CallDetailsOutcomes.Contains(root.GetProperty("outcome").GetString())) return false;

        var startedAtRaw = root.GetProperty("startedAt");
        if (startedAtRaw.ValueKind != JsonValueKind.String ||
            !DateTimeOffset.TryParse(startedAtRaw.GetString(), out var startedAt))
            return false;

        var endedAtRaw = root.GetProperty("endedAt");
        if (endedAtRaw.ValueKind == JsonValueKind.Null) return true;
        if (endedAtRaw.ValueKind != JsonValueKind.String ||
            !DateTimeOffset.TryParse(endedAtRaw.GetString(), out var endedAt))
            return false;
        return endedAt >= startedAt;
    }

    // edit | delete | reaction (M §4.2 X0-M-2): exactly {"ref","bodyHash"}.
    // ref = the target message id in canonical UUID form; bodyHash = 64 hex
    // (SHA-256 of the UTF-8 new text / emoji) for edit and reaction, JSON null
    // for delete (a deletion has no new content). The archiver computes the
    // hash, so the auditor can later match an edit to a claimed text without
    // the archive ever holding that text.
    private static bool IsWellFormedRefDetails(string kind, string details)
    {
        if (details.Length > RefDetailsMaxLength) return false;
        if (!TryParseObject(details, out var root)) return false;

        var keys = root.EnumerateObject().Select(p => p.Name).ToList();
        if (keys.Count != RefDetailsKeys.Length || !RefDetailsKeys.All(keys.Contains)) return false;

        var reference = root.GetProperty("ref");
        if (reference.ValueKind != JsonValueKind.String ||
            !Guid.TryParseExact(reference.GetString(), "D", out _))
            return false;

        var bodyHash = root.GetProperty("bodyHash");
        return kind == "delete"
            ? bodyHash.ValueKind == JsonValueKind.Null
            : bodyHash.ValueKind == JsonValueKind.String && ContentHashPattern().IsMatch(bodyHash.GetString()!);
    }

    // other (K2): exactly {"type": "<1..32 chars, no control characters>"}.
    // Control characters are refused because an admin reads this value
    // directly; the archiver truncates/sanitizes the wire type before sending.
    private static bool IsWellFormedOtherDetails(string details)
    {
        if (details.Length > OtherDetailsMaxLength) return false;
        if (!TryParseObject(details, out var root)) return false;

        var props = root.EnumerateObject().ToList();
        if (props.Count != 1 || props[0].Name != "type" || props[0].Value.ValueKind != JsonValueKind.String) return false;

        var type = props[0].Value.GetString()!;
        return type.Length is > 0 and <= OtherTypeMaxLength && !type.Any(char.IsControl);
    }

    private static bool TryParseObject(string json, out JsonElement root)
    {
        root = default;
        try
        {
            // Clone: the element must outlive the JsonDocument that parsed it.
            using var doc = JsonDocument.Parse(json);
            root = doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return false;
        }
        return root.ValueKind == JsonValueKind.Object;
    }

    private static async Task<IResult> GetCount(Guid orgId, ClaimsPrincipal user, BusinessModeOptions businessMode,
        HttpContext http, AppDbContext appDb, TimeProvider clock, CancellationToken ct)
    {
        if (!businessMode.Enabled) return Results.Json(new { error = "business_mode_disabled" }, statusCode: StatusCodes.Status503ServiceUnavailable);

        // Resolved lazily for the same startup-safety reason as in PostRecord.
        var auditDb = http.RequestServices.GetRequiredService<AuditDbContext>();

        var callerDevice = Caller(user);
        if (callerDevice == Guid.Empty) return Results.Unauthorized();

        var org = await auditDb.Organizations.SingleOrDefaultAsync(o => o.OrganizationId == orgId, ct);
        if (org is null) return Results.NotFound();

        // The JWT identifies a device, but org governance (KB6) is per-account —
        // resolve the caller's linked account(s) and check for an active
        // OrgAdmin-or-above membership. A device with no linked account (e.g. an
        // anonymous member device) simply has no admin role anywhere.
        var accountIds = await appDb.AccountDevices.Where(ad => ad.DeviceId == callerDevice)
            .Select(ad => ad.AccountId).ToListAsync(ct);
        var adminAccountId = accountIds.Count == 0 ? (Guid?)null : await auditDb.OrgMembers
            .Where(m => m.OrganizationId == orgId && accountIds.Contains(m.AccountId) && m.RemovedAt == null &&
                        (m.Role == OrgRole.Owner || m.Role == OrgRole.OrgAdmin))
            .Select(m => (Guid?)m.AccountId).FirstOrDefaultAsync(ct);
        if (adminAccountId is null) return Results.Forbid();

        // N03b: this endpoint IS admin-gated (isAdmin check above), so — unlike
        // PostRecord, which is the archiver bot's own path and stays open — it
        // requires the same fresh MFA step-up as every other OrgAdmin+ read.
        if (MfaAuthHelper.RequireStepUp(user, adminAccountId.Value, clock) is { } stepUpRequired) return stepUpRequired;

        var last = await auditDb.AuditRecords.Where(r => r.OrganizationId == orgId)
            .OrderByDescending(r => r.Sequence).FirstOrDefaultAsync(ct);
        var count = await auditDb.AuditRecords.CountAsync(r => r.OrganizationId == orgId, ct);

        // Liveness signal (added on top of the original count/lastSequence/lastHash):
        // an admin can't otherwise tell a dead archiver from a quiet one until
        // queued messages expire (30 days). Both queries stay index-friendly —
        // "last" above already covers lastArchivedAt (ArchivedAt only ever
        // increases with Sequence, so the row we already fetched has it), and
        // the QueuedMessage lookup uses the existing (RecipientId, CreatedAt)
        // index. AuditDbContext has no index beyond OrganizationId today; adding
        // one requires an audit-DB migration, which is applied manually in
        // production (see CLAUDE.md) — flagged in the final report, not added here.
        int pendingForAuditor = 0;
        DateTimeOffset? oldestPendingAt = null;
        if (org.AuditorDeviceId is { } auditorDeviceId)
        {
            var pendingQuery = appDb.QueuedMessages
                .Where(m => m.RecipientId == auditorDeviceId && m.AcknowledgedAt == null);
            pendingForAuditor = await pendingQuery.CountAsync(ct);
            oldestPendingAt = pendingForAuditor > 0
                ? await pendingQuery.OrderBy(m => m.CreatedAt).Select(m => (DateTimeOffset?)m.CreatedAt).FirstAsync(ct)
                : null;
        }

        return Results.Ok(new AuditRecordCountDto(count, last?.Sequence ?? 0,
            last is null ? null : Convert.ToHexString(last.Hash),
            last?.ArchivedAt, pendingForAuditor, oldestPendingAt));
    }
}

public record ArchiveRecordRequest(Guid GroupId, Guid MessageId, Guid SenderDeviceId, DateTimeOffset SentAt,
    string Kind, long SizeBytes, string ContentHash, string? Details = null);

public record AuditRecordDto(Guid OrganizationId, Guid GroupId, Guid MessageId, Guid SenderDeviceId,
    DateTimeOffset SentAt, DateTimeOffset ArchivedAt, string Kind, long SizeBytes, string ContentHash,
    long Sequence, string Hash, string? Details = null);

public record AuditRecordCountDto(int Count, long LastSequence, string? LastHash,
    DateTimeOffset? LastArchivedAt, int PendingForAuditor, DateTimeOffset? OldestPendingAt);
