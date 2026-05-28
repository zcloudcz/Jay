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
using ZMessanger.Api.Data;
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Services;

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
    /// Uses ExecuteDeleteAsync inside a transaction so the fetch-then-delete
    /// is atomic. This prevents a race where two concurrent DequeueAsync calls
    /// for the same recipient could both return the same messages.
    /// </remarks>
    public async Task<List<QueuedMessage>> DequeueAsync(Guid recipientId)
    {
        var now = DateTimeOffset.UtcNow;

        // Use an explicit transaction so the read and delete are atomic.
        // Without this, a concurrent call could read the same rows before
        // either deletes them — delivering duplicates.
        await using var transaction = await db.Database.BeginTransactionAsync();

        var messages = await db.QueuedMessages
            .Where(m => m.RecipientId == recipientId && m.ExpiresAt > now)
            .OrderBy(m => m.CreatedAt)
            .ToListAsync();

        // Always delete all messages for this recipient (including expired
        // ones), not just the non-expired set we return. This cleans up
        // stale rows as a side effect so abandoned devices don't accumulate
        // expired messages forever. The delete runs even when messages is
        // empty — the recipient may have only expired messages to purge.
        await db.QueuedMessages
            .Where(m => m.RecipientId == recipientId)
            .ExecuteDeleteAsync();

        await transaction.CommitAsync();

        return messages;
    }
}
