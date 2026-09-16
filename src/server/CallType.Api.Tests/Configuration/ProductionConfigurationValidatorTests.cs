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
