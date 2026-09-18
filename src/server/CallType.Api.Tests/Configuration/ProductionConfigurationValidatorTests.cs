// ---------------------------------------------------------------------------
// ProductionConfigurationValidatorTests.cs — startup config guard
// ---------------------------------------------------------------------------
// The validator must reject a Production boot with insecure/default config,
// and must never leak the offending value in the exception message — only
// the config key name. Development must stay unaffected so docker-compose
// local dev keeps working.
// ---------------------------------------------------------------------------

using CallType.Api.Configuration;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace CallType.Api.Tests.Configuration;

public class ProductionConfigurationValidatorTests
{
    private static IConfiguration BuildConfig(Dictionary<string, string?> values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values).Build();

    private static readonly Dictionary<string, string?> ValidProductionConfig = new()
    {
        ["Jwt:Secret"] = "a-real-production-secret-that-is-long-enough!!",
        ["ConnectionStrings:DefaultConnection"] = "Host=db;Port=5432;Database=calltype;Username=calltype;Password=S3cure-Prod-Pass",
        ["ConnectionStrings:BlobStorage"] = "DefaultEndpointsProtocol=https;AccountName=real;AccountKey=abc123;EndpointSuffix=core.windows.net",
        ["Turn:SharedSecret"] = "a-real-turn-secret",
        ["Cors:AllowedOrigins:0"] = "https://calltype.example.com"
    };

    private static IHostEnvironment Env(string name) => new HostingEnvironmentStub(name);

    [Fact]
    public void Valid_production_config_does_not_throw()
    {
        var config = BuildConfig(ValidProductionConfig);
        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));
        act.Should().NotThrow();
    }

    [Fact]
    public void Development_environment_skips_validation_even_with_insecure_values()
    {
        var config = BuildConfig(new Dictionary<string, string?>()); // nothing configured
        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Development));
        act.Should().NotThrow();
    }

    [Fact]
    public void Missing_jwt_secret_is_rejected_by_key_name_only()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig);
        values.Remove("Jwt:Secret");
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*Jwt:Secret*");
    }

    [Fact]
    public void Short_jwt_secret_is_rejected()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig) { ["Jwt:Secret"] = "too-short" };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*Jwt:Secret*");
    }

    [Fact]
    public void Known_dev_jwt_secret_is_rejected_and_value_never_appears_in_message()
    {
        const string devSecret = "REPLACE_ME_IN_PRODUCTION_MIN_32_CHARS_LONG!!";
        var values = new Dictionary<string, string?>(ValidProductionConfig) { ["Jwt:Secret"] = devSecret };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        var ex = act.Should().Throw<InvalidOperationException>().Which;
        ex.Message.Should().Contain("Jwt:Secret");
        ex.Message.Should().NotContain(devSecret);
    }

    [Fact]
    public void Default_postgres_password_is_rejected()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:DefaultConnection"] = "Host=localhost;Port=5432;Database=calltype;Username=postgres;Password=postgres"
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*ConnectionStrings:DefaultConnection*");
    }

    [Fact]
    public void Cloudflare_provider_requires_key_id_and_token_but_not_shared_secret()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["Turn:Provider"] = "cloudflare",
            ["Turn:SharedSecret"] = null, // irrelevant for Cloudflare — must not be demanded
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        var ex = act.Should().Throw<InvalidOperationException>().Which;
        ex.Message.Should().Contain("Turn:Cloudflare:KeyId").And.Contain("Turn:Cloudflare:ApiToken");
        ex.Message.Should().NotContain("Turn:SharedSecret");
    }

    [Fact]
    public void Cloudflare_provider_with_key_id_and_token_is_accepted()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["Turn:Provider"] = "cloudflare",
            ["Turn:SharedSecret"] = null,
            ["Turn:Cloudflare:KeyId"] = "0123456789abcdef",
            ["Turn:Cloudflare:ApiToken"] = "cf-token",
        };

        var act = () => ProductionConfigurationValidator.Validate(BuildConfig(values), Env(Environments.Production));

        act.Should().NotThrow();
    }

    [Fact]
    public void Password_that_merely_starts_with_postgres_is_accepted()
    {
        // Regression: a substring check rejected any password beginning with "postgres".
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:DefaultConnection"] = "Host=db.example;Port=5432;Database=calltype;Username=app;Password=postgresql-is-not-the-default-9f3a"
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().NotThrow();
    }

    [Fact]
    public void Development_storage_emulator_blob_connection_is_rejected()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:BlobStorage"] = "UseDevelopmentStorage=true"
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*ConnectionStrings:BlobStorage*");
    }

    [Fact]
    public void Known_dev_turn_secret_is_rejected()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig) { ["Turn:SharedSecret"] = "REPLACE_ME_IN_PRODUCTION" };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*Turn:SharedSecret*");
    }

    [Fact]
    public void Missing_explicit_cors_origins_is_rejected()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig);
        values.Remove("Cors:AllowedOrigins:0");
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*Cors:AllowedOrigins*");
    }

    [Fact]
    public void Missing_audit_connection_does_not_block_startup()
    {
        // Business mode is opt-in — an anonymous-only deployment must not be
        // forced to configure ConnectionStrings:Audit.
        var config = BuildConfig(ValidProductionConfig);
        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));
        act.Should().NotThrow();
    }

    [Fact]
    public void Audit_connection_with_dev_password_is_rejected()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:Audit"] = "Host=db;Port=5432;Database=calltype_audit;Username=calltype_audit;Password=postgres"
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*ConnectionStrings:Audit*");
    }

    [Fact]
    public void Audit_connection_identical_to_default_connection_is_rejected()
    {
        // Separate credentials are the whole point of KB3 — reusing the
        // Delivery connection string defeats the blast-radius isolation even
        // when the password isn't the well-known dev default.
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:Audit"] = ValidProductionConfig["ConnectionStrings:DefaultConnection"]
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*ConnectionStrings:Audit*");
    }

    [Fact]
    public void Audit_connection_reusing_the_delivery_database_user_is_rejected()
    {
        // Same login role, different database and parameter order: a raw string
        // comparison would let this through, yet a leaked Delivery credential
        // would still open the audit archive (KB3).
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:DefaultConnection"] = "Host=db;Port=5432;Database=calltype;Username=calltype;Password=S3cure-Prod-Pass",
            ["ConnectionStrings:Audit"] = "Password=S3cure-Prod-Pass;Username=calltype;Database=calltype_audit;Port=5432;Host=db"
        };

        var act = () => ProductionConfigurationValidator.Validate(BuildConfig(values), Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*ConnectionStrings:Audit*");
    }

    [Fact]
    public void Audit_connection_with_separate_valid_credentials_is_accepted()
    {
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:Audit"] = "Host=audit-db;Port=5432;Database=calltype_audit;Username=calltype_audit;Password=S3cure-Audit-Pass",
            // Required once ConnectionStrings:Audit is set (N03) — see Mfa_EncryptionKey_* tests below.
            ["Mfa:EncryptionKey"] = "ZGV2LW1mYS1rZXktMzItYnl0ZXMtbG9jYWwtb25seSE="
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().NotThrow();
    }

    [Fact]
    public void Audit_connection_without_mfa_encryption_key_is_rejected()
    {
        // N03: MFA is mandatory for Owner/OrgAdmin/AuditorApprover once Business
        // mode is on — booting without a key would leave org administration
        // permanently locked (every MFA endpoint 503, every step-up check 403).
        var values = new Dictionary<string, string?>(ValidProductionConfig)
        {
            ["ConnectionStrings:Audit"] = "Host=audit-db;Port=5432;Database=calltype_audit;Username=calltype_audit;Password=S3cure-Audit-Pass"
        };
        var config = BuildConfig(values);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().Throw<InvalidOperationException>().WithMessage("*Mfa:EncryptionKey*");
    }

    [Fact]
    public void Mfa_encryption_key_is_not_required_when_business_mode_is_off()
    {
        // Anonymous-only deployments (no ConnectionStrings:Audit) must not be
        // forced to set an MFA key they'll never use.
        var config = BuildConfig(ValidProductionConfig);

        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));

        act.Should().NotThrow();
    }

    [Fact]
    public void Missing_firebase_config_does_not_block_startup()
    {
        // Push:FcmServiceAccountJson intentionally absent — Firebase is optional.
        var config = BuildConfig(ValidProductionConfig);
        var act = () => ProductionConfigurationValidator.Validate(config, Env(Environments.Production));
        act.Should().NotThrow();
    }

    /// <summary>Minimal IHostEnvironment stub — avoids pulling in a full WebApplicationFactory for a pure unit test.</summary>
    private sealed class HostingEnvironmentStub(string environmentName) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = environmentName;
        public string ApplicationName { get; set; } = "CallType.Api.Tests";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } = null!;
    }
}
