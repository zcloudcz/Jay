// ---------------------------------------------------------------------------
// BackupLimitsOptions.cs — Configuration for backup quota limits (K03)
// ---------------------------------------------------------------------------
// Conservative development defaults, not an approved production capacity
// plan — see docs/superpowers/plans/2026-09-16-beta-kontrakty.md K03.
// Bound from the "BackupLimits" configuration section (BackupLimits__MaxFileBytes
// etc. as env vars, same double-underscore convention as the rest of the app).
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class BackupLimitsOptions
{
    public const string SectionName = "BackupLimits";

    /// <summary>Max size of a single encrypted backup file, in bytes. 8 MiB default.</summary>
    public long MaxFileBytes { get; set; } = 8 * 1024 * 1024;

    /// <summary>Max number of completed-or-reserved backups per account. 3 default.</summary>
    public int MaxPerAccount { get; set; } = 3;

    /// <summary>Max sum of reserved+stored bytes across the whole installation. 256 MiB default.</summary>
    public long MaxTotalBytes { get; set; } = 256 * 1024 * 1024;
}
