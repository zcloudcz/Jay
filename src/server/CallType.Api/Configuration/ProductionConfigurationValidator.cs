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

        var dbConnection = configuration.GetConnectionString("DefaultConnection");
        if (dbConnection is not null &&
            dbConnection.Contains("Password=postgres", StringComparison.OrdinalIgnoreCase))
            violations.Add("ConnectionStrings:DefaultConnection");

        var blobConnection = configuration.GetConnectionString("BlobStorage");
        if (blobConnection is not null &&
            blobConnection.Contains("UseDevelopmentStorage=true", StringComparison.OrdinalIgnoreCase))
            violations.Add("ConnectionStrings:BlobStorage");

        var turnSecret = configuration["Turn:SharedSecret"];
        if (string.IsNullOrEmpty(turnSecret) ||
            turnSecret.StartsWith("REPLACE_ME_IN_PRODUCTION", StringComparison.Ordinal))
            violations.Add("Turn:SharedSecret");

        var corsOrigins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>();
        if (corsOrigins is not { Length: > 0 })
            violations.Add("Cors:AllowedOrigins");

        // Push:FcmServiceAccountJson is intentionally NOT validated — Firebase
        // is optional, and PushNotificationService already no-ops when it's empty.

        if (violations.Count > 0)
            throw new InvalidOperationException(
                $"Production startup rejected — invalid or missing configuration for: {string.Join(", ", violations)}.");
    }
}
