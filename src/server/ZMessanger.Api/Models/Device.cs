// ---------------------------------------------------------------------------
// Device.cs — Represents a single client device (phone, desktop, etc.)
// ---------------------------------------------------------------------------
// Each device has its own X3DH key bundle (identity key + signed pre-key)
// so the server can broker key exchanges without ever seeing plaintext.
// UserHandle is a short, human-readable alias (e.g. "alice#1234") that
// clients use to discover each other; it is unique across the system.
// ---------------------------------------------------------------------------

namespace ZMessanger.Api.Models;

public class Device
{
    public Guid DeviceId { get; set; }

    /// <summary>
    /// Short, human-readable device alias in format "ZM-XXXX-XXXX" (12 chars).
    /// Unique across the system — used for device discovery during key exchange.
    /// </summary>
    public string UserHandle { get; set; } = string.Empty;

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
