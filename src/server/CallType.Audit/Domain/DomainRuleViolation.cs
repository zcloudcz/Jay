// ---------------------------------------------------------------------------
// DomainRuleViolation.cs — invariant-violation exception for Org & Audit
// ---------------------------------------------------------------------------
// Carries a stable, machine-readable Code (e.g. "last_admin", "self_approval",
// "invite_invalid") so callers further up the stack (E01/E04 endpoints) can
// map it to the right HTTP status/error body without parsing Message text,
// which is free-form and may change.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class DomainRuleViolation(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
