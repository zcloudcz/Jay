// ---------------------------------------------------------------------------
// ProductionConfigurationValidator.cs — startup guard for Production config
// ---------------------------------------------------------------------------
// Fails fast at startup if Production is about to run with a missing,
// too-short, or known-development secret/config value. Development (used by
// docker-compose local dev) is intentionally exempt so local workflows keep
// working unchanged.
//
// The exception message names only the offending config KEY, never its
// value — the value may itself be a secret, and this message can end up in
// logs or crash reports.
// ---------------------------------------------------------------------------

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace CallType.Api.Configuration;

public static class ProductionConfigurationValidator
{
    private const int MinJwtSecretLength = 32;

    private static bool SameDatabaseUser(string a, string b)
    {
        try
        {
            var ua = new Npgsql.NpgsqlConnectionStringBuilder(a).Username;
            var ub = new Npgsql.NpgsqlConnectionStringBuilder(b).Username;
            return !string.IsNullOrEmpty(ua) && string.Equals(ua, ub, StringComparison.Ordinal);
        }
        catch (ArgumentException)
        {
            return false; // Malformed string fails later at connect with a clearer error.
        }
    }

    private static bool IsDevPostgresPassword(string connectionString)
    {
        try
        {
            var builder = new Npgsql.NpgsqlConnectionStringBuilder(connectionString);
            return string.Equals(builder.Password, "postgres", StringComparison.Ordinal);
        }
        catch (ArgumentException)
        {
            return false; // Malformed string fails later at DB connect with a clearer error.
        }
    }

    public static void Validate(IConfiguration configuration, IHostEnvironment environment)
    {
        if (!environment.IsProduction())
            return;

        var violations = new List<string>();

        var jwtSecret = configuration["Jwt:Secret"];
        if (string.IsNullOrEmpty(jwtSecret))
            violations.Add("Jwt:Secret");
        else if (jwtSecret.Length < MinJwtSecretLength)
            violations.Add("Jwt:Secret");
        else if (jwtSecret.StartsWith("REPLACE_ME_IN_PRODUCTION", StringComparison.Ordinal))
            violations.Add("Jwt:Secret");

        // Parse instead of substring-matching so a legitimate password that merely
        // starts with "postgres" is not rejected; only the exact dev default is.
        var dbConnection = configuration.GetConnectionString("DefaultConnection");
        if (dbConnection is not null && IsDevPostgresPassword(dbConnection))
            violations.Add("ConnectionStrings:DefaultConnection");

        // Audit connection is only checked if configured at all — Business mode
        // is opt-in (BusinessModeOptions), so an anonymous-only deployment must
        // not be forced to set it just to pass this validator.
        var auditConnection = configuration.GetConnectionString("Audit");
        if (!string.IsNullOrEmpty(auditConnection))
        {
            if (IsDevPostgresPassword(auditConnection))
                violations.Add("ConnectionStrings:Audit");
            // Separate credentials are the whole point (KB3): a compromised
            // Delivery connection must not also unlock the audit DB. Reusing
            // DefaultConnection verbatim defeats that even if the password
            // itself isn't the well-known dev default.
            // Comparing raw strings would miss the same role written with different
            // formatting/parameter order, so compare the login role itself.
            else if (dbConnection is not null && SameDatabaseUser(auditConnection, dbConnection))
                violations.Add("ConnectionStrings:Audit");

            // MFA is mandatory for Owner/OrgAdmin/AuditorApprover (N03) once
            // business mode is on — without this key every MFA endpoint
            // answers 503 and organization administration stays locked, so
            // boot must fail loudly instead of deploying into that state.
            if (string.IsNullOrEmpty(configuration["Mfa:EncryptionKey"]))
                violations.Add("Mfa:EncryptionKey");
        }

        var blobConnection = configuration.GetConnectionString("BlobStorage");
        if (blobConnection is not null &&
            blobConnection.Contains("UseDevelopmentStorage=true", StringComparison.OrdinalIgnoreCase))
            violations.Add("ConnectionStrings:BlobStorage");

        // Only the active TURN provider's settings are required; a stale coturn
        // secret must not block a Cloudflare deployment and vice versa.
        if (string.Equals(configuration["Turn:Provider"], "cloudflare", StringComparison.OrdinalIgnoreCase))
        {
            if (string.IsNullOrEmpty(configuration["Turn:Cloudflare:KeyId"]))
                violations.Add("Turn:Cloudflare:KeyId");
            if (string.IsNullOrEmpty(configuration["Turn:Cloudflare:ApiToken"]))
                violations.Add("Turn:Cloudflare:ApiToken");
        }
        else
        {
            var turnSecret = configuration["Turn:SharedSecret"];
            if (string.IsNullOrEmpty(turnSecret) ||
                turnSecret.StartsWith("REPLACE_ME_IN_PRODUCTION", StringComparison.Ordinal))
                violations.Add("Turn:SharedSecret");
        }

        var corsOrigins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>();
        if (corsOrigins is not { Length: > 0 })
            violations.Add("Cors:AllowedOrigins");

        // Push:FcmServiceAccountJson is intentionally NOT validated — Firebase
        // is optional, and PushNotificationService already no-ops when it's empty.

        // APNs is optional too (empty = iOS push off, same as FCM), but a HALF
        // configured APNs is always an operator mistake that would only show
        // up as silently missing iOS calls — so all-or-nothing. BundleId alone
        // does not count as "configured": appsettings.json ships a default
        // bundle id, and that must not force every deployment to set the key.
        string[] apnsCredentialKeys = ["Push:Apns:TeamId", "Push:Apns:KeyId", "Push:Apns:PrivateKeyP8"];
        if (apnsCredentialKeys.Any(key => !string.IsNullOrEmpty(configuration[key])))
        {
            foreach (var key in apnsCredentialKeys.Append("Push:Apns:BundleId"))
                if (string.IsNullOrEmpty(configuration[key]))
                    violations.Add(key);
        }

        if (violations.Count > 0)
            throw new InvalidOperationException(
                $"Production startup rejected — invalid or missing configuration for: {string.Join(", ", violations)}.");
    }
}
