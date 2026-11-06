// ---------------------------------------------------------------------------
// PushPayloads.cs - Provider-specific JSON bodies (pure, golden-tested)
// ---------------------------------------------------------------------------
// Kept apart from the HTTP senders so the exact wire shape of each provider
// can be asserted byte for byte in unit tests (PushPayloadsTests) without a
// network or a database. JsonObject keeps insertion order, so the golden
// strings are stable.
// ---------------------------------------------------------------------------

using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CallType.Api.Services;

public static class PushPayloads
{
    // Relaxed escaping writes "Nová zpráva" as UTF-8 instead of \u escapes:
    // the bodies go to provider APIs, never into HTML, and every byte counts
    // against the 4 KB Web Push / APNs payload limits.
    private static readonly JsonSerializerOptions Wire = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>The exact bytes-as-text sent to a provider.</summary>
    public static string Serialize(JsonObject payload) => payload.ToJsonString(Wire);

    /// <summary>
    /// FCM HTTP v1 message. A visible "notification" block (not data-only as
    /// before): Android shows it itself while the app is killed, which is the
    /// only case a server push matters. tag + collapse_key collapse one chat
    /// into one notification; channel_id must match the app's Android
    /// notification channels (messages, calls, channels).
    /// </summary>
    public static JsonObject Fcm(string token, PushNotification n, string? locale) => new()
    {
        ["message"] = new JsonObject
        {
            ["token"] = token,
            ["notification"] = new JsonObject
            {
                ["title"] = PushTexts.Title,
                ["body"] = PushTexts.Body(n.Type, locale),
            },
            ["android"] = new JsonObject
            {
                ["priority"] = "high",
                ["collapse_key"] = n.ConversationId,
                ["notification"] = new JsonObject
                {
                    ["tag"] = n.ConversationId,
                    ["channel_id"] = AndroidChannel(n.Type),
                },
            },
            ["data"] = Data(n),
        },
    };

    /// <summary>
    /// APNs body. thread-id groups a chat in Notification Center;
    /// mutable-content lets a later Notification Service Extension replace the
    /// generic text with a decrypted preview (out of scope now, N7). The data
    /// keys sit at the top level, next to "aps", as Apple prescribes for
    /// custom keys.
    /// </summary>
    public static JsonObject Apns(PushNotification n, string? locale) => new()
    {
        ["aps"] = new JsonObject
        {
            ["alert"] = new JsonObject
            {
                ["title"] = PushTexts.Title,
                ["body"] = PushTexts.Body(n.Type, locale),
            },
            ["sound"] = "default",
            ["thread-id"] = n.ConversationId,
            ["mutable-content"] = 1,
        },
        ["type"] = n.Type,
        ["conversationId"] = n.ConversationId,
        ["v"] = PushNotification.Version,
    };

    /// <summary>
    /// Web Push plaintext (encrypted before it leaves the server). The service
    /// worker shows title/body and uses tag to replace the previous
    /// notification of the same chat.
    /// </summary>
    public static JsonObject WebPush(PushNotification n, string? locale) => new()
    {
        ["title"] = PushTexts.Title,
        ["body"] = PushTexts.Body(n.Type, locale),
        ["type"] = n.Type,
        ["conversationId"] = n.ConversationId,
        ["v"] = PushNotification.Version,
        ["tag"] = n.ConversationId,
    };

    /// <summary>
    /// FCM ring message (incoming_call or call_cancelled with a call id):
    /// data-only, NO "notification" block, so Android hands it to the app's
    /// background handler even when the app is killed, and the app shows a
    /// full-screen call notification instead of a plain one. ttl 45 s = the
    /// caller's ring timeout: a ring delivered later than that would ring for
    /// a call that no longer exists.
    /// </summary>
    public static JsonObject FcmRing(string token, PushNotification n) => new()
    {
        ["message"] = new JsonObject
        {
            ["token"] = token,
            ["android"] = new JsonObject
            {
                ["priority"] = "high",
                ["ttl"] = "45s",
            },
            ["data"] = RingData(n),
        },
    };

    /// <summary>
    /// PushKit VoIP body. "aps" stays empty: a VoIP push is never shown by
    /// iOS itself, the app must report it to CallKit right away. Same data
    /// keys as the FCM ring, at the top level like every APNs custom key.
    /// </summary>
    public static JsonObject ApnsVoip(PushNotification n)
    {
        var body = new JsonObject { ["aps"] = new JsonObject() };
        foreach (var (key, value) in RingData(n))
            body[key] = value?.DeepClone();
        return body;
    }

    /// <summary>Ring data keys in contract order: type, callId, conversationId, v.</summary>
    private static JsonObject RingData(PushNotification n) => new()
    {
        ["type"] = n.Type,
        ["callId"] = n.CallId,
        ["conversationId"] = n.ConversationId,
        ["v"] = PushNotification.Version,
    };

    private static JsonObject Data(PushNotification n) => new()
    {
        ["type"] = n.Type,
        ["conversationId"] = n.ConversationId,
        ["v"] = PushNotification.Version,
    };

    internal static string AndroidChannel(string type) => type switch
    {
        PushTypes.IncomingCall => "calls",
        PushTypes.ChannelPost => "channels",
        _ => "messages",
    };
}
