// ---------------------------------------------------------------------------
// BusinessModeOptions.cs — whether Business mode is available (plan §0/§3)
// ---------------------------------------------------------------------------
// Business mode (organizations, audit archive) is entirely opt-in: it turns
// on only when ConnectionStrings:Audit is configured. Anonymous-mode
// deployments (the default) never touch CallType.Audit, and the existing
// product must keep working completely unchanged (plan decision 1). Later
// packages (E01+) check Enabled and return 503 "business_mode_disabled"
// instead of assuming AuditDbContext is registered.
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class BusinessModeOptions
{
    public bool Enabled { get; init; }
}
