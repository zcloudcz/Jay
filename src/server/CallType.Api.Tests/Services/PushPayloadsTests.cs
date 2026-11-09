// ---------------------------------------------------------------------------
// PushPayloadsTests.cs - Golden wire shapes of the three push providers
// ---------------------------------------------------------------------------
// The app (Android channels, iOS thread grouping, the web service worker)
// codes against these exact keys (spec 2026-11-06-notifications, 1.3), so the
// whole JSON is compared as a string, not just a few fields.
// ---------------------------------------------------------------------------

using FluentAssertions;
using CallType.Api.Services;

namespace CallType.Api.Tests.Services;

public class PushPayloadsTests
{
    private const string Conv = "3f2b7c1e-9a4d-4c55-8f10-6d2e1a7b9c01";

    [Fact]
    public void Fcm_message_is_visible_collapsed_and_carries_the_route()
    {
        var json = PushPayloads.Serialize(PushPayloads.Fcm("tok", new PushNotification(PushTypes.Message, Conv), "cs-CZ"));

        json.Should().Be(
            "{\"message\":{\"token\":\"tok\"," +
            "\"notification\":{\"title\":\"Jay\",\"body\":\"Nová zpráva\"}," +
            "\"android\":{\"priority\":\"high\",\"collapse_key\":\"" + Conv + "\"," +
            "\"notification\":{\"tag\":\"" + Conv + "\",\"channel_id\":\"messages\"}}," +
            "\"data\":{\"type\":\"message\",\"conversationId\":\"" + Conv + "\",\"v\":\"1\"}}}");
    }

    [Theory]
    [InlineData(PushTypes.Message, "messages")]
    [InlineData(PushTypes.GroupMessage, "messages")]
    [InlineData(PushTypes.IncomingCall, "calls")]
    [InlineData(PushTypes.ChannelPost, "channels")]
    public void Fcm_android_channel_matches_the_app_channels(string type, string channel)
    {
        var json = PushPayloads.Serialize(PushPayloads.Fcm("t", new PushNotification(type, Conv), null));
        json.Should().Contain($"\"channel_id\":\"{channel}\"");
    }

    [Fact]
    public void Apns_body_has_alert_thread_and_top_level_data()
    {
        var json = PushPayloads.Serialize(PushPayloads.Apns(new PushNotification(PushTypes.IncomingCall, Conv), "en-US"));

        json.Should().Be(
            "{\"aps\":{\"alert\":{\"title\":\"Jay\",\"body\":\"Incoming call\"},\"sound\":\"default\"," +
            "\"thread-id\":\"" + Conv + "\",\"mutable-content\":1}," +
            "\"type\":\"incoming_call\",\"conversationId\":\"" + Conv + "\",\"v\":\"1\"}");
    }

    [Fact]
    public void WebPush_plaintext_has_texts_route_and_tag()
    {
        var json = PushPayloads.Serialize(PushPayloads.WebPush(new PushNotification(PushTypes.ChannelPost, Conv), "cs"));

        json.Should().Be(
            "{\"title\":\"Jay\",\"body\":\"Nový příspěvek v kanálu\",\"type\":\"channel_post\"," +
            "\"conversationId\":\"" + Conv + "\",\"v\":\"1\",\"tag\":\"" + Conv + "\"}");
    }

    private const string CallId = "8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f";

    [Fact]
    public void Fcm_ring_is_data_only_high_priority_with_45s_ttl()
    {
        var json = PushPayloads.Serialize(PushPayloads.FcmRing("tok",
            PushNotification.ForRing(Guid.Parse(Conv), CallId)));

        json.Should().Be(
            "{\"message\":{\"token\":\"tok\"," +
            "\"android\":{\"priority\":\"high\",\"ttl\":\"45s\"}," +
            "\"data\":{\"type\":\"incoming_call\",\"callId\":\"" + CallId + "\"," +
            "\"conversationId\":\"" + Conv + "\",\"v\":\"1\"}}}");
    }

    [Fact]
    public void Fcm_call_cancelled_has_the_ring_shape()
    {
        var json = PushPayloads.Serialize(PushPayloads.FcmRing("tok",
            PushNotification.ForCallCancelled(Guid.Parse(Conv), CallId)));

        json.Should().Be(
            "{\"message\":{\"token\":\"tok\"," +
            "\"android\":{\"priority\":\"high\",\"ttl\":\"45s\"}," +
            "\"data\":{\"type\":\"call_cancelled\",\"callId\":\"" + CallId + "\"," +
            "\"conversationId\":\"" + Conv + "\",\"v\":\"1\"}}}");
    }

    [Fact]
    public void Apns_voip_body_has_empty_aps_and_the_call_route()
    {
        var json = PushPayloads.Serialize(PushPayloads.ApnsVoip(PushNotification.ForRing(Guid.Parse(Conv), CallId)));

        json.Should().Be(
            "{\"aps\":{},\"type\":\"incoming_call\",\"callId\":\"" + CallId + "\"," +
            "\"conversationId\":\"" + Conv + "\",\"v\":\"1\"}");
    }

    [Theory]
    [InlineData(PushTypes.Message, "cs", "Nová zpráva")]
    [InlineData(PushTypes.Message, "en", "New message")]
    [InlineData(PushTypes.GroupMessage, "cs_CZ", "Nová zpráva ve skupině")]
    [InlineData(PushTypes.GroupMessage, null, "New message in a group")]
    [InlineData(PushTypes.IncomingCall, "CS", "Příchozí hovor")]
    [InlineData(PushTypes.IncomingCall, "de-DE", "Incoming call")]
    [InlineData(PushTypes.ChannelPost, "cs-CZ", "Nový příspěvek v kanálu")]
    [InlineData(PushTypes.ChannelPost, "en-GB", "New post in a channel")]
    // "csb" (Kashubian) starts with "cs" but is not Czech.
    [InlineData(PushTypes.Message, "csb", "New message")]
    public void Texts_are_chosen_by_language_prefix(string type, string? locale, string expected) =>
        PushTexts.Body(type, locale).Should().Be(expected);

    [Fact]
    public void Message_route_is_the_group_or_the_senders_identity()
    {
        var group = Guid.NewGuid();
        var sender = Guid.NewGuid();

        PushNotification.ForMessage(group, sender).Should().Be(new PushNotification("group_message", group.ToString()));
        PushNotification.ForMessage(null, sender).Should().Be(new PushNotification("message", sender.ToString()));
    }

    [Fact]
    public void WebPush_topic_is_32_url_safe_chars_and_stable_per_conversation()
    {
        var topic = PushCollapse.WebPushTopic(Conv);

        topic.Should().HaveLength(32).And.MatchRegex("^[A-Za-z0-9_-]{32}$");
        PushCollapse.WebPushTopic(Conv).Should().Be(topic);
        PushCollapse.WebPushTopic(Guid.NewGuid().ToString()).Should().NotBe(topic);
    }

    [Fact]
    public void Apns_collapse_id_is_the_conversation_and_never_over_64_bytes()
    {
        PushCollapse.ApnsCollapseId(Conv).Should().Be(Conv);
        PushCollapse.ApnsCollapseId(new string('x', 100)).Should().HaveLength(64);
    }
}
