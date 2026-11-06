// ---------------------------------------------------------------------------
// PushContent.cs - What a server push says, independent of the provider
// ---------------------------------------------------------------------------
// The server has no plaintext (E2E), and a sender or group name would leak
// metadata to Apple/Google, so every push is a GENERIC localized text plus the
// conversation id the app needs to open the right chat on tap. Contract:
// docs/superpowers/specs/2026-11-06-notifications.md section 1.3.
// ---------------------------------------------------------------------------

using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;

namespace CallType.Api.Services;

/// <summary>The four push types of the contract (data key "type").</summary>
public static class PushTypes
{
    public const string Message = "message";
    public const string GroupMessage = "group_message";
    public const string IncomingCall = "incoming_call";
    public const string ChannelPost = "channel_post";
}

/// <summary>
/// One push to one device. <paramref name="ConversationId"/> = group id for
/// group messages, the sender's PRIMARY device id for 1:1 (conversations are
/// keyed by identity on the client), channel id for channel posts.
/// </summary>
public sealed record PushNotification(string Type, string ConversationId)
{
    /// <summary>Wire version of the data payload, lets the app evolve the format.</summary>
    public const string Version = "1";

    public static PushNotification ForMessage(Guid? groupId, Guid senderPrimary) => groupId is { } g
        ? new(PushTypes.GroupMessage, g.ToString())
        : new(PushTypes.Message, senderPrimary.ToString());

    public static PushNotification ForCall(Guid conversationId) => new(PushTypes.IncomingCall, conversationId.ToString());

    public static PushNotification ForChannelPost(Guid channelId) => new(PushTypes.ChannelPost, channelId.ToString());
}

/// <summary>Result of one provider send, drives token clearing.</summary>
public enum PushSendResult
{
    /// <summary>Accepted by the provider.</summary>
    Sent,

    /// <summary>Provider says the token/subscription is dead: clear it.</summary>
    TokenInvalid,

    /// <summary>Transient or unknown failure: keep the token.</summary>
    Failed,

    /// <summary>The provider is not configured on this server.</summary>
    Disabled,
}

/// <summary>
/// One push provider. Implementations never throw for a provider failure
/// (they map it to <see cref="PushSendResult"/>), so a push can never break
/// the hub call that triggered it.
/// </summary>
public interface IPushSender
{
    /// <summary>Value of Device.PushPlatform this sender serves: fcm, apns or webpush.</summary>
    string Platform { get; }

    bool IsConfigured { get; }

    Task<PushSendResult> SendAsync(string token, PushNotification notification, string? locale, CancellationToken ct);
}

/// <summary>Generic texts, chosen by the device's registered locale.</summary>
public static class PushTexts
{
    public const string Title = "Jay";

    /// <summary>
    /// Czech for any "cs" locale (cs, cs-CZ, cs_CZ), English otherwise: the two
    /// languages the product is run in today. The app localizes its own local
    /// notifications in all its languages; these few strings only appear while
    /// the app is not running.
    /// </summary>
    public static string Body(string type, string? locale)
    {
        var czech = IsCzech(locale);
        return type switch
        {
            PushTypes.GroupMessage => czech ? "Nová zpráva ve skupině" : "New message in a group",
            PushTypes.IncomingCall => czech ? "Příchozí hovor" : "Incoming call",
            PushTypes.ChannelPost => czech ? "Nový příspěvek v kanálu" : "New post in a channel",
            _ => czech ? "Nová zpráva" : "New message",
        };
    }

    private static bool IsCzech(string? locale) =>
        locale is not null && locale.StartsWith("cs", StringComparison.OrdinalIgnoreCase)
        && (locale.Length == 2 || locale[2] is '-' or '_');
}

/// <summary>Collapse identifiers shared by the provider payload builders.</summary>
public static class PushCollapse
{
    /// <summary>
    /// Web Push Topic: RFC 8030 limits it to 32 base64url characters, a GUID
    /// string is 36. Hashing (instead of truncating) keeps different
    /// conversations from colliding on a shared prefix and does not reveal
    /// the conversation id to the push service in a second header.
    /// </summary>
    public static string WebPushTopic(string conversationId) =>
        Base64Url.EncodeToString(SHA256.HashData(Encoding.UTF8.GetBytes(conversationId)))[..32];

    /// <summary>apns-collapse-id may be at most 64 bytes; a GUID always fits, anything else is cut.</summary>
    public static string ApnsCollapseId(string conversationId)
    {
        if (Encoding.UTF8.GetByteCount(conversationId) <= 64) return conversationId;
        // Not reachable with GUID ids; hash instead of cutting mid-character.
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(conversationId))).ToLowerInvariant();
    }
}
