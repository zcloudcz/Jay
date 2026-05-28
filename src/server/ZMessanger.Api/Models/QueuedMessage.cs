// ---------------------------------------------------------------------------
// QueuedMessage.cs — Encrypted message waiting for delivery
// ---------------------------------------------------------------------------
// The server acts as a store-and-forward relay. Messages are opaque
// encrypted blobs (EncryptedBody) — the server cannot read them. They sit
// in the queue until the recipient device pulls them, after which the
// server deletes them. ExpiresAt enables automatic cleanup of messages
// that were never fetched (e.g. abandoned devices).
// ---------------------------------------------------------------------------

namespace ZMessanger.Api.Models;

public class QueuedMessage
{
    /// <summary>
    /// Server-assigned surrogate key, auto-incremented. Provides a total
    /// order for delivery within a recipient's queue.
    /// </summary>
    public long Id { get; set; }

    /// <summary>
    /// The DeviceId of the intended recipient. Indexed together with
    /// CreatedAt to support efficient "fetch all pending messages" queries.
    /// </summary>
    public Guid RecipientId { get; set; }

    /// <summary>
    /// The DeviceId of the sender. Stored so the recipient can route the
    /// decrypted payload to the correct conversation.
    /// </summary>
    public Guid SenderId { get; set; }

    /// <summary>
    /// The full encrypted message payload (Signal protocol ciphertext).
    /// The server treats this as an opaque blob — it never decrypts it.
    /// </summary>
    public byte[] EncryptedBody { get; set; } = [];

    public DateTime CreatedAt { get; set; }

    /// <summary>
    /// After this timestamp the message is eligible for garbage collection.
    /// Prevents unbounded storage growth from abandoned devices.
    /// </summary>
    public DateTime ExpiresAt { get; set; }
}
