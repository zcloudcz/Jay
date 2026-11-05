// ---------------------------------------------------------------------------
// ChannelLogicTests.cs — DB-free unit tests for the pure channel rules
// ---------------------------------------------------------------------------
// Covers what can be verified without PostgreSQL/Docker: the push throttle
// ("max 1 push / channel / window"), the lowercase kind contract, the emoji
// whitelist, poll validation and the tombstone/anonymity shape of the hub
// event. The HTTP behaviour on top of these is in ChannelEndpointsTests.
// ---------------------------------------------------------------------------

using System.Text.Json;
using FluentAssertions;
using CallType.Api.Models;
using CallType.Api.Services;

namespace CallType.Api.Tests.Services;

public class ChannelLogicTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 17, 12, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(10);

    // --- Push throttle -------------------------------------------------------

    [Fact]
    public void Throttle_allows_one_push_per_channel_per_window()
    {
        var throttle = new ChannelPushThrottle();
        var channel = Guid.NewGuid();

        throttle.TryAcquire(channel, Now, Window).Should().BeTrue("the first post always pushes");
        throttle.TryAcquire(channel, Now.AddMinutes(1), Window).Should().BeFalse();
        throttle.TryAcquire(channel, Now.AddMinutes(9.99), Window).Should().BeFalse();
        throttle.TryAcquire(channel, Now.AddMinutes(10), Window).Should().BeTrue("the window has elapsed");
        // The window restarts at the last SENT push, not at the first one.
        throttle.TryAcquire(channel, Now.AddMinutes(15), Window).Should().BeFalse();
    }

    [Fact]
    public void Throttle_is_independent_per_channel()
    {
        var throttle = new ChannelPushThrottle();

        throttle.TryAcquire(Guid.NewGuid(), Now, Window).Should().BeTrue();
        throttle.TryAcquire(Guid.NewGuid(), Now, Window).Should().BeTrue();
    }

    [Fact]
    public void Throttle_lets_exactly_one_of_many_parallel_posts_push()
    {
        var throttle = new ChannelPushThrottle();
        var channel = Guid.NewGuid();
        var acquired = 0;

        Parallel.For(0, 200, _ =>
        {
            if (throttle.TryAcquire(channel, Now, Window)) Interlocked.Increment(ref acquired);
        });

        acquired.Should().Be(1);
    }

    // --- Kind ----------------------------------------------------------------

    [Theory]
    [InlineData("text", ChannelPostKind.Text)]
    [InlineData("image", ChannelPostKind.Image)]
    [InlineData("poll", ChannelPostKind.Poll)]
    public void ParseKind_accepts_lowercase_api_values(string api, ChannelPostKind expected)
    {
        ChannelService.ParseKind(api).Should().Be(expected);
        ChannelService.KindToApi(expected).Should().Be(api);
    }

    [Theory]
    [InlineData("video")] // no video in v1 (plan §7.2)
    [InlineData("Text")]  // contract is lowercase only
    [InlineData("1")]     // Enum.TryParse would accept this — we must not
    [InlineData("")]
    [InlineData(null)]
    public void ParseKind_rejects_everything_else(string? api)
    {
        ChannelService.ParseKind(api).Should().BeNull();
    }

    // --- Emoji ---------------------------------------------------------------

    [Fact]
    public void NormalizeEmoji_accepts_exactly_the_six_whitelisted()
    {
        ChannelService.AllowedEmoji.Should().HaveCount(6);
        foreach (var emoji in ChannelService.AllowedEmoji)
            ChannelService.NormalizeEmoji(emoji).Should().Be(emoji);
    }

    [Fact]
    public void NormalizeEmoji_adds_variation_selector_to_bare_heart()
    {
        ChannelService.NormalizeEmoji("❤").Should().Be("❤️");
    }

    [Theory]
    [InlineData("\U0001F4A9")]             // an emoji, but not whitelisted
    [InlineData("\U0001F44D\U0001F44D")]   // two graphemes
    [InlineData("ok")]
    [InlineData("")]
    [InlineData(null)]
    public void NormalizeEmoji_rejects_anything_else(string? emoji)
    {
        ChannelService.NormalizeEmoji(emoji).Should().BeNull();
    }

    // --- Poll ----------------------------------------------------------------

    [Fact]
    public void Poll_is_normalized_to_canonical_camelCase_json()
    {
        var ok = ChannelService.TryNormalizePoll(
            """{ "question": " Lunch? ", "options": [" Pizza ", "Soup"], "extra": 1 }""",
            Now, out var normalized, out var error);

        ok.Should().BeTrue(error);
        var json = JsonDocument.Parse(normalized).RootElement;
        json.GetProperty("question").GetString().Should().Be("Lunch?");
        json.GetProperty("options").EnumerateArray().Select(o => o.GetString())
            .Should().Equal("Pizza", "Soup");
        json.GetProperty("closesAt").ValueKind.Should().Be(JsonValueKind.Null);
        json.TryGetProperty("extra", out _).Should().BeFalse("unknown properties are dropped");

        ChannelService.ParseStoredPoll(normalized).Options.Should().HaveCount(2);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("""{ "question": "Q" }""")]                                  // options missing
    [InlineData("""{ "question": "", "options": ["a", "b"] }""")]            // empty question
    [InlineData("""{ "question": "Q", "options": ["a"] }""")]                // < 2 options
    [InlineData("""{ "question": "Q", "options": ["a", " "] }""")]           // blank option
    [InlineData("""{ "question": "Q", "options": ["a", 5] }""")]             // non-string option
    [InlineData("""{ "question": "Q", "options": ["1","2","3","4","5","6","7","8","9","10","11"] }""")]
    [InlineData("""{ "question": "Q", "options": ["a", "b"], "closesAt": "2026-09-17T11:00:00Z" }""")] // past
    public void Invalid_poll_is_rejected(string body)
    {
        ChannelService.TryNormalizePoll(body, Now, out _, out var error).Should().BeFalse();
        error.Should().NotBeEmpty();
    }

    [Fact]
    public void Poll_with_future_closesAt_is_accepted_and_stored_as_utc()
    {
        ChannelService.TryNormalizePoll(
            """{ "question": "Q", "options": ["a", "b"], "closesAt": "2026-09-18T14:00:00+02:00" }""",
            Now, out var normalized, out _).Should().BeTrue();

        ChannelService.ParseStoredPoll(normalized).ClosesAt
            .Should().Be(new DateTimeOffset(2026, 9, 18, 12, 0, 0, TimeSpan.Zero));
    }

    // --- Hub event shape -----------------------------------------------------

    [Fact]
    public void Post_event_never_contains_the_author_and_blanks_deleted_content()
    {
        var author = Guid.NewGuid();
        var post = new ChannelPost
        {
            PostId = Guid.NewGuid(),
            ChannelId = Guid.NewGuid(),
            AuthorDeviceId = author,
            Kind = ChannelPostKind.Image,
            Body = "secret caption",
            AttachmentBlobPath = "channel-media/x/y.png",
            CreatedAt = Now
        };

        var live = JsonSerializer.Serialize(ChannelService.PostEvent(post, false));
        live.Should().NotContain(author.ToString());
        live.Should().Contain("secret caption").And.Contain("\"kind\":\"image\"").And.Contain("\"deleted\":false");

        post.DeletedAt = Now;
        var tombstone = JsonSerializer.Serialize(ChannelService.PostEvent(post, false));
        tombstone.Should().Contain("\"deleted\":true");
        tombstone.Should().NotContain("secret caption").And.NotContain("channel-media");
    }
}
