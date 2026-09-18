// ---------------------------------------------------------------------------
// EmergencyCodesTests.cs — E07 offline-enrollment code generation + hashing
// ---------------------------------------------------------------------------
// DB-free by design (Application layer only) — run with:
//   dotnet test src/server/CallType.Api.Tests --filter "FullyQualifiedName~Audit"
// ---------------------------------------------------------------------------

using CallType.Audit.Emergency;
using FluentAssertions;

namespace CallType.Api.Tests.Audit;

public class EmergencyCodesTests
{
    [Fact]
    public void Generate_produces_unique_codes()
    {
        var codes = Enumerable.Range(0, 1000).Select(_ => EmergencyCodes.Generate()).ToList();

        codes.Distinct().Should().HaveCount(codes.Count);
    }

    [Fact]
    public void Generate_only_uses_crockford_base32_characters_and_dashes()
    {
        var code = EmergencyCodes.Generate();

        code.Should().MatchRegex("^[0-9A-Z-]+$");
        code.Should().NotContain("I").And.NotContain("L").And.NotContain("O").And.NotContain("U");
    }

    [Fact]
    public void Hash_is_deterministic_for_the_same_code()
    {
        var code = EmergencyCodes.Generate();

        EmergencyCodes.Hash(code).Should().Be(EmergencyCodes.Hash(code));
    }

    [Fact]
    public void Hash_is_insensitive_to_dashes_and_case()
    {
        const string code = "7k2m-9qrt-xv34-abcd";

        EmergencyCodes.Hash(code).Should().Be(EmergencyCodes.Hash("7K2M9QRTXV34ABCD"));
    }

    [Fact]
    public void Hash_never_returns_the_plaintext_code()
    {
        var code = EmergencyCodes.Generate();

        EmergencyCodes.Hash(code).Should().NotContain(code);
    }

    [Fact]
    public void Different_codes_hash_differently()
    {
        var a = EmergencyCodes.Generate();
        var b = EmergencyCodes.Generate();

        EmergencyCodes.Hash(a).Should().NotBe(EmergencyCodes.Hash(b));
    }
}
