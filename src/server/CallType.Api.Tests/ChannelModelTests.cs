// ---------------------------------------------------------------------------
// ChannelModelTests.cs — DB-free unit tests for handles, options and EF model
// ---------------------------------------------------------------------------
// These need no Docker: the EF model is built from AppDbContext without ever
// opening a connection, so keys and indexes can be checked on any machine.
// The real database behaviour is covered by ChannelSchemaTests (Testcontainers).
// ---------------------------------------------------------------------------

using System.Text.RegularExpressions;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.Extensions.Configuration;
using CallType.Api.Configuration;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Services;

namespace CallType.Api.Tests;

public class ChannelModelTests
{
    // The connection string is never used — building the model does not connect.
    private static AppDbContext NewOfflineDb() => new(
        new DbContextOptionsBuilder<AppDbContext>().UseNpgsql("Host=unused").Options);

    [Theory]
    [InlineData("CT")]
    [InlineData("CH")]
    public void Handle_has_prefix_and_two_groups_from_the_unambiguous_alphabet(string prefix)
    {
        var pattern = new Regex($"^{prefix}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{{4}}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{{4}}$");

        for (var i = 0; i < 200; i++)
            HandleGenerator.Generate(prefix).Should().MatchRegex(pattern);
    }

    [Fact]
    public void Channels_options_have_the_agreed_defaults()
    {
        var options = new ChannelsOptions();

        options.PostRetentionDays.Should().Be(90);
        options.MaxOwnedPerDevice.Should().Be(5);
        options.MaxImageBytes.Should().Be(2 * 1024 * 1024);
        options.ReportNotifyEmail.Should().BeEmpty();
        options.PushThrottleMinutes.Should().Be(10);
    }

    [Fact]
    public void Channels_options_bind_from_the_Channels_section()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Channels:PostRetentionDays"] = "30",
            ["Channels:ReportNotifyEmail"] = "ops@example.com"
        }).Build();

        var options = config.GetSection(ChannelsOptions.SectionName).Get<ChannelsOptions>()!;

        options.PostRetentionDays.Should().Be(30);
        options.ReportNotifyEmail.Should().Be("ops@example.com");
        options.MaxOwnedPerDevice.Should().Be(5, "keys that are not configured keep their default");
    }

    [Fact]
    public void Post_kind_has_no_video()
    {
        // Owner decision 2026-09-17: v1 is text / image / poll only.
        Enum.GetNames<ChannelPostKind>().Should().BeEquivalentTo("Text", "Image", "Poll");
    }

    [Fact]
    public void Channel_handle_is_unique_and_twelve_chars()
    {
        using var db = NewOfflineDb();
        var channel = db.Model.FindEntityType(typeof(Channel))!;

        channel.FindProperty(nameof(Channel.Handle))!.GetMaxLength().Should().Be(12);
        channel.GetIndexes().Should().Contain(i =>
            i.IsUnique && i.Properties.Single().Name == nameof(Channel.Handle));
    }

    [Theory]
    [InlineData(typeof(ChannelAdmin), "ChannelId", "DeviceId")]
    [InlineData(typeof(ChannelFollower), "ChannelId", "DeviceId")]
    [InlineData(typeof(ChannelReaction), "PostId", "DeviceId")]
    [InlineData(typeof(ChannelPollVote), "PostId", "DeviceId")]
    public void Per_device_tables_use_a_composite_primary_key(Type entity, string first, string second)
    {
        using var db = NewOfflineDb();

        db.Model.FindEntityType(entity)!.FindPrimaryKey()!.Properties.Select(p => p.Name)
            .Should().Equal(first, second);
    }

    [Fact]
    public void Post_feed_index_is_channel_then_newest_first()
    {
        using var db = NewOfflineDb();
        // Sort direction is design-time-only metadata — the read-optimized
        // runtime model (db.Model) throws when asked for it.
        var model = db.GetService<IDesignTimeModel>().Model;
        var index = model.FindEntityType(typeof(ChannelPost))!.GetIndexes()
            .Single(i => i.Properties.Count == 2);

        index.Properties.Select(p => p.Name).Should().Equal("ChannelId", "CreatedAt");
        index.IsDescending.Should().Equal(false, true);
    }

    [Fact]
    public void Device_IsBot_defaults_to_false()
    {
        new Device().IsBot.Should().BeFalse();
    }
}
