// ---------------------------------------------------------------------------
// Dtos.cs — E07 application-service result shapes (Audit DB only)
// ---------------------------------------------------------------------------

namespace CallType.Audit.Emergency;

public record IssuedKit(Guid KitId, string Label, DateTimeOffset IssuedAt, string RecoveryCode, IReadOnlyList<string> Codes);

public record KitSummary(Guid KitId, string Label, DateTimeOffset IssuedAt, DateTimeOffset? RevokedAt, int CodesTotal, int CodesRemaining);

public record DrillSummary(long DrillId, DateTimeOffset StartedAt, DateTimeOffset? CompletedAt, int ConfirmedMemberCount, TimeSpan? ResponseTime);

/// <summary>Result of redeeming an emergency code — <see cref="OrganizationId"/> is what the
/// caller (CallType.Api) needs to add the device to the org's emergency group.</summary>
public record EmergencyEnrollResult(Guid OrganizationId, bool AlreadyEnrolled);
