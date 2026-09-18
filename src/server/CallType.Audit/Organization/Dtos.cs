// ---------------------------------------------------------------------------
// Dtos.cs — data shapes returned by OrganizationAppService
// ---------------------------------------------------------------------------
// Kept separate from the Domain aggregates on purpose: these are read
// projections for the API, not persisted state, so they're free to change
// shape without touching the aggregates E00 froze.
// ---------------------------------------------------------------------------

using CallType.Audit.Domain;

namespace CallType.Audit.OrgManagement;

public record OrganizationSummary(Guid OrganizationId, string Name, OrgRole Role, ArchiveLevel ArchiveLevel, Guid? AuditorDeviceId);

public record OrganizationDetails(Guid OrganizationId, string Name, DateTimeOffset CreatedAt, ArchiveLevel ArchiveLevel, Guid? AuditorDeviceId, IReadOnlyList<OrgMemberDto> Members);

public record OrgMemberDto(Guid AccountId, OrgRole Role, DateTimeOffset AddedAt);

public record InviteDto(string Code, DateTimeOffset ExpiresAt);

public record AdminAuditEventDto(long Sequence, Guid ActorAccountId, string EventType, string DetailsJson, DateTimeOffset OccurredAt);
