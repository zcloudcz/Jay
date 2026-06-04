// ---------------------------------------------------------------------------
// OneTimePreKey.cs — Expendable X3DH one-time pre-keys
// ---------------------------------------------------------------------------
// Each device uploads a batch of one-time pre-keys. When another device
// initiates a session, the server hands out exactly one key and deletes it.
// This provides forward secrecy: even if the signed pre-key is later
// compromised, past sessions established with a consumed one-time key
// remain secure.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class OneTimePreKey
{
    /// <summary>
    /// Server-assigned surrogate key. Auto-incremented — the client-facing
    /// identifier is <see cref="KeyId"/>, which the device chooses.
    /// </summary>
    public long Id { get; set; }

    public Guid DeviceId { get; set; }

    /// <summary>
    /// Client-assigned key identifier. Combined with DeviceId, it uniquely
    /// identifies the key so the recipient can tell the sender which key
    /// was used during the X3DH handshake.
    /// </summary>
    public int KeyId { get; set; }

    /// <summary>
    /// The actual Curve25519 public key bytes.
    /// </summary>
    public byte[] PublicKey { get; set; } = [];

    // Navigation property
    public Device Device { get; set; } = null!;
}
