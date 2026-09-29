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
    /// X3DH long-term identity public key. Clients verify this never changes
    /// for a given device to detect MITM attacks.
    /// </summary>
    public byte[] IdentityKey { get; set; } = [];

    /// <summary>
    /// X3DH signed pre-key. The server stores only the latest version so new
    /// contacts can initiate sessions. The client rotates it via
    /// PUT /devices/{id}/signed-prekey (stream S2), see <see cref="SignedPreKeyId"/>.
    /// Until S2 ships, clients never rotate it (fixed keyId 1).
    /// </summary>
    public byte[] SignedPreKey { get; set; } = [];

    /// <summary>
    /// Client-assigned id of <see cref="SignedPreKey"/> (X3DH references the
    /// SPK by id). Defaults to 1 because every client before S2 registered its
    /// only SPK with the hard-coded keyId 1 — the migration backfills exactly
    /// that value for existing rows.
    /// </summary>
    public int SignedPreKeyId { get; set; } = 1;

    /// <summary>
    /// When the SPK was last replaced via PUT signed-prekey. Null = never
    /// rotated since registration (every device before S2).
    /// </summary>
    public DateTimeOffset? SignedPreKeyUpdatedAt { get; set; }

    public byte[]? SigningKey { get; set; }
    public byte[]? Signature { get; set; }

    /// <summary>
    /// Platform-specific push notification token (APNs / FCM).
    /// Null when the device has not registered for push or has revoked it.
    /// </summary>
    public string? PushToken { get; set; }

    /// <summary>
    /// Push platform identifier (e.g. "apns", "fcm"). Null when PushToken is null.
    /// Max 10 chars — kept short because the set of platforms is small and fixed.
    /// </summary>
    public string? PushPlatform { get; set; }

    /// <summary>
    /// APNs PushKit token, separate from the alert token in PushToken — an
    /// iPhone has both (FCM/APNs alert token for messages, PushKit for calls).
    /// Written by PUT push-token with platform "apns-voip"; "apns-voip" is
    /// never stored in <see cref="PushPlatform"/>. Max 200 chars (hex, 64 today).
    /// </summary>
    public string? VoipPushToken { get; set; }

    /// <summary>
    /// "production" or "sandbox" — only a client hint for which APNs gateway
    /// the PushKit token belongs to; the push sender (stream N) corrects it
    /// from APNs responses. Null when unknown.
    /// </summary>
    public string? VoipPushEnvironment { get; set; }

    /// <summary>
    /// Exactly 32 bytes: key the push sender uses to encrypt the metadata hint
    /// in a push payload. Not a secret towards this server — its purpose is to
    /// keep sender/conversation ids away from Google and Apple, who relay the push.
    /// </summary>
    public byte[]? PushKey { get; set; }

    /// <summary>
    /// Set on every PUT push-token. Diagnostics, and lets the sender decide
    /// whether an APNs 410 (which carries a timestamp) is older than the
    /// token currently stored before deleting it.
    /// </summary>
    public DateTimeOffset? PushTokenUpdatedAt { get; set; }

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
