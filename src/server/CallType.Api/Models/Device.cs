// ---------------------------------------------------------------------------
// Device.cs — Represents a single client device (phone, desktop, etc.)
// ---------------------------------------------------------------------------
// Each device has its own X3DH key bundle (identity key + signed pre-key)
// so the server can broker key exchanges without ever seeing plaintext.
// UserHandle is a short, human-readable alias (e.g. "CT-ABCD-EF23") that
// clients use to discover each other; it is unique across the system.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class Device
{
    public Guid DeviceId { get; set; }

    /// <summary>
    /// Short, human-readable device alias in format "CT-XXXX-XXXX" (12 chars).
    /// Unique across the system — used for device discovery during key exchange.
    /// </summary>
    public string UserHandle { get; set; } = string.Empty;

    /// <summary>
    /// Optional display name the device owner chose to show contacts who add
    /// them (e.g. via QR/handle). Same trust level as UserHandle: plaintext,
    /// server-visible discovery metadata, never message content. Null means
    /// "show the handle" — an anonymous device is never forced to pick one.
    /// </summary>
    public string? DisplayName { get; set; }

    /// <summary>
    /// X3DH long-term identity public key. Clients verify this never changes
    /// for a given device to detect MITM attacks.
    /// </summary>
    public byte[] IdentityKey { get; set; } = [];

    /// <summary>
    /// X3DH signed pre-key — rotated periodically by the client.
    /// The server stores the latest version so new contacts can initiate sessions.
    /// </summary>
    public byte[] SignedPreKey { get; set; } = [];

    public byte[]? SigningKey { get; set; }
    public byte[]? Signature { get; set; }

    /// <summary>
    /// Platform-specific push notification token (APNs / FCM).
    /// Null when the device has not registered for push or has revoked it.
    /// </summary>
    public string? PushToken { get; set; }

    /// <summary>
    /// Push platform identifier ("fcm", "apns" or "webpush"). Null when PushToken is null.
    /// Max 10 chars — kept short because the set of platforms is small and fixed.
    /// </summary>
    public string? PushPlatform { get; set; }

    /// <summary>
    /// BCP-47 locale the app registered with its push token (e.g. "cs",
    /// "en-US"), max 16. Server pushes are generic texts the SERVER renders
    /// (the app is not running to localize them), so it needs the language.
    /// Null = English. Cleared together with the token.
    /// </summary>
    public string? PushLocale { get; set; }

    /// <summary>
    /// iOS PushKit (VoIP) token, lowercase hex, max 200. Separate from
    /// <see cref="PushToken"/> because iOS hands out a different token for
    /// VoIP pushes and the alert token keeps serving messages. A device with
    /// this token can ring (CallKit) while the app is closed; spec
    /// 2026-11-06-call-ringing R2. Cleared by DELETE voip-token, by DELETE
    /// push-token (logout) and when APNs reports it dead.
    /// </summary>
    public string? VoipPushToken { get; set; }

    /// <summary>
    /// The Android app declared (push-token registration, <c>ringCalls</c>)
    /// that it handles data-only ring pushes with a full-screen call
    /// notification. Explicit opt-in because an older app would silently
    /// drop a data-only push and the call would neither ring nor show
    /// "Incoming call". Only ever true for platform "fcm".
    /// </summary>
    public bool PushRingCalls { get; set; }

    /// <summary>
    /// SHA-256 hash of the device secret issued at registration time.
    /// The raw secret is returned once to the client and never stored.
    /// Authentication works by hashing the client-provided secret and
    /// comparing it to this value — same pattern as API key auth.
    /// </summary>
    public byte[] DeviceSecretHash { get; set; } = null!;

    /// <summary>
    /// True when the device declared itself an automated bot at registration.
    /// Self-declaration, not verification — it only drives the "BOT" badge in
    /// clients. Immutable: set once in POST /devices, no endpoint updates it.
    /// For queueing, TTL, rate limits and push a bot is an ordinary device.
    /// </summary>
    public bool IsBot { get; set; }

    /// <summary>
    /// The bot's published command list ("/help - Show help") as JSON
    /// (<c>[{"command","description"}]</c>), set only by the bot itself via
    /// PUT /devices/{id}/bot-commands. Public plaintext metadata like
    /// DisplayName, never message content. Stored as one text column rather
    /// than a child table because it is always read and replaced as a whole
    /// and is small (max 50 entries). Null means "no list published".
    /// </summary>
    public string? BotCommandsJson { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>
    /// Updated on every authenticated API call from this device.
    /// Used for stale-device cleanup and rate-limiting heuristics.
    /// </summary>
    public DateTimeOffset LastSeenAt { get; set; }

    // Navigation properties
    public List<OneTimePreKey> OneTimePreKeys { get; set; } = [];
    public List<AccountDevice> AccountDevices { get; set; } = [];
    public List<GroupMember> GroupMemberships { get; set; } = [];
}
