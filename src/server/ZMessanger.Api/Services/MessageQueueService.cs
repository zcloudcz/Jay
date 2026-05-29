// ---------------------------------------------------------------------------
// MessageQueueService.cs — Store-and-forward queue for encrypted messages
// ---------------------------------------------------------------------------
// When a recipient device is offline, messages are stored as opaque encrypted
// blobs in the database. When the device reconnects, the hub drains the queue
// and delivers everything in FIFO order. A 30-day TTL prevents unbounded
// storage growth from abandoned devices — expired messages are filtered out
// at read time (a background cleanup job can purge them separately).
//
// The server never decrypts EncryptedBody; it is a pass-through relay.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Npgsql;
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Services;

/// <summary>
/// Result type for the atomic DELETE ... RETURNING dequeue query.
/// Must be a class with a parameterless constructor for EF Core's
/// SqlQueryRaw materialization.
/// </summary>
public class DequeuedMessage
{
    public long Id { get; set; }
    public Guid SenderId { get; set; }
    public byte[] EncryptedBody { get; set; } = null!;
    public DateTimeOffset CreatedAt { get; set; }
}

public class MessageQueueService(AppDbContext db)
{
    private static readonly TimeSpan MessageTtl = TimeSpan.FromDays(30);

    /// <summary>
    /// Stores an encrypted message for a device that is currently offline.
    /// The message will sit in the queue until the recipient connects and
    /// calls <see cref="DequeueAsync"/>, or until it expires after 30 days.
    /// </summary>
    public async Task EnqueueAsync(Guid recipientId, Guid senderId, byte[] encryptedBody)
    {
        var now = DateTimeOffset.UtcNow;

        var message = new QueuedMessage
        {
            RecipientId = recipientId,
            SenderId = senderId,
            EncryptedBody = encryptedBody,
            CreatedAt = now,
            ExpiresAt = now + MessageTtl
        };

        db.QueuedMessages.Add(message);
        await db.SaveChangesAsync();
    }

    /// <summary>
    /// Retrieves and deletes all pending messages for a recipient in FIFO order.
    /// Expired messages are excluded — they will be cleaned up separately.
    /// </summary>
    /// <remarks>
    /// Uses a single DELETE ... RETURNING statement (same pattern as OTK
    /// consumption in DeviceEndpoints.cs) so the read and delete are atomic
    /// without an explicit transaction. FOR UPDATE SKIP LOCKED prevents
    /// concurrent dequeue calls from returning the same messages.
    /// </remarks>
    public async Task<List<DequeuedMessage>> DequeueAsync(Guid recipientId)
    {
        // DELETE ... RETURNING does not guarantee row order, so we sort in
        // application code after the atomic delete to ensure FIFO delivery.
        var messages = await db.Database.SqlQueryRaw<DequeuedMessage>("""
            DELETE FROM "QueuedMessages"
            WHERE "Id" IN (
                SELECT "Id" FROM "QueuedMessages"
                WHERE "RecipientId" = @recipientId AND "ExpiresAt" > now()
                ORDER BY "CreatedAt"
                FOR UPDATE SKIP LOCKED
            )
            RETURNING "Id", "SenderId", "EncryptedBody", "CreatedAt"
            """, new NpgsqlParameter("@recipientId", recipientId))
            .ToListAsync();

        messages.Sort((a, b) => a.CreatedAt.CompareTo(b.CreatedAt));

        // Clean up any expired messages for this recipient as a side effect.
        // This runs as a separate statement — it won't affect the returned
        // result set and keeps abandoned devices from accumulating stale rows.
        await db.QueuedMessages
            .Where(m => m.RecipientId == recipientId && m.ExpiresAt <= DateTimeOffset.UtcNow)
            .ExecuteDeleteAsync();

        return messages;
    }
}
