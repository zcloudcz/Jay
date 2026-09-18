// ---------------------------------------------------------------------------
// HashChainTests.cs — canonical serialization + chained hash (KB3/KB6, E00)
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using CallType.Audit.Application;
using FluentAssertions;

namespace CallType.Api.Tests.Audit;

public class HashChainTests
{
    [Fact]
    public void Genesis_is_32_zero_bytes()
    {
        HashChain.Genesis.Should().HaveCount(32).And.OnlyContain(b => b == 0);
    }

    [Fact]
    public void ComputeHash_is_deterministic_for_the_same_input()
    {
        var canonical = HashChain.Canonicalize(["org-1", "group-1", "msg-1"]);

        var hash1 = HashChain.ComputeHash(HashChain.Genesis, canonical);
        var hash2 = HashChain.ComputeHash(HashChain.Genesis, canonical);

        hash1.Should().Equal(hash2);
        hash1.Should().HaveCount(HashChain.HashLength);
    }

    [Fact]
    public void ComputeHash_changes_when_the_previous_hash_changes()
    {
        var canonical = HashChain.Canonicalize(["org-1", "group-1", "msg-1"]);
        var otherPrevHash = SHA256.HashData("something-else"u8.ToArray());

        var hashFromGenesis = HashChain.ComputeHash(HashChain.Genesis, canonical);
        var hashFromOtherPrev = HashChain.ComputeHash(otherPrevHash, canonical);

        hashFromGenesis.Should().NotEqual(hashFromOtherPrev);
    }

    [Fact]
    public void ComputeHash_changes_when_the_record_changes()
    {
        var hash1 = HashChain.ComputeHash(HashChain.Genesis, HashChain.Canonicalize(["msg-1"]));
        var hash2 = HashChain.ComputeHash(HashChain.Genesis, HashChain.Canonicalize(["msg-2"]));

        hash1.Should().NotEqual(hash2);
    }

    [Fact]
    public void Canonicalize_distinguishes_field_boundaries_that_naive_concatenation_would_collide()
    {
        // Regression guard for the exact bug the Unit Separator is there to prevent:
        // ("ab","c") and ("a","bc") must not canonicalize to the same string.
        var a = HashChain.Canonicalize(["ab", "c"]);
        var b = HashChain.Canonicalize(["a", "bc"]);

        a.Should().NotBe(b);
    }

    [Fact]
    public void Canonicalize_distinguishes_null_from_empty_string()
    {
        // If null and "" hashed the same, swapping one for the other in a stored
        // row would not break the chain — i.e. tampering would go undetected.
        string? nullField = null;

        HashChain.Canonicalize([nullField]).Should().NotBe(HashChain.Canonicalize([string.Empty]));
    }

    [Theory]
    [InlineData("ab")]
    [InlineData("a\0b")]
    public void Canonicalize_rejects_values_containing_reserved_control_characters(string value)
    {
        // Otherwise ("ab") would canonicalize identically to ("a","b").
        var act = () => HashChain.Canonicalize([value]);

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void A_three_link_chain_verifies_by_recomputing_each_hash_in_order()
    {
        var record1 = HashChain.Canonicalize(["record-1"]);
        var record2 = HashChain.Canonicalize(["record-2"]);
        var record3 = HashChain.Canonicalize(["record-3"]);

        var hash1 = HashChain.ComputeHash(HashChain.Genesis, record1);
        var hash2 = HashChain.ComputeHash(hash1, record2);
        var hash3 = HashChain.ComputeHash(hash2, record3);

        // Offline verification recomputes the same chain from scratch and must agree.
        HashChain.ComputeHash(HashChain.Genesis, record1).Should().Equal(hash1);
        HashChain.ComputeHash(hash1, record2).Should().Equal(hash2);
        HashChain.ComputeHash(hash2, record3).Should().Equal(hash3);

        // Tampering with a middle record breaks every hash after it — the point of the chain.
        var tamperedRecord2 = HashChain.Canonicalize(["record-2-tampered"]);
        var tamperedHash2 = HashChain.ComputeHash(hash1, tamperedRecord2);
        tamperedHash2.Should().NotEqual(hash2);
    }
}
