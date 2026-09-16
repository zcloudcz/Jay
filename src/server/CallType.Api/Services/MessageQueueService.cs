using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;
using CallType.Api.Models;

namespace CallType.Api.Services;

public class DequeuedMessage
{
    public long Id { get; set; }
    public Guid MessageId { get; set; }
    public Guid SenderId { get; set; }
    public Guid? GroupId { get; set; }
    public byte[] EncryptedBody { get; set; } = [];
    public DateTimeOffset CreatedAt { get; set; }
}

public class MessageQueueService(AppDbContext db)
{
    private static readonly TimeSpan MessageTtl = TimeSpan.FromDays(30);

    public async Task EnqueueAsync(Guid recipientId, Guid senderId, byte[] encryptedBody)
        => await EnqueueReliableAsync(recipientId, senderId, Guid.NewGuid(), encryptedBody);

    public async Task<QueuedMessage> EnqueueReliableAsync(Guid recipientId, Guid senderId,
        Guid messageId, byte[] encryptedBody, Guid? groupId = null, CancellationToken cancellationToken = default)
    {
        if (recipientId == Guid.Empty || senderId == Guid.Empty || messageId == Guid.Empty)
            throw new ArgumentException("Device and message IDs must be non-empty UUIDs");
        var now = DateTimeOffset.UtcNow;
        var expiresAt = now + MessageTtl;
        // The unique key plus ON CONFLICT makes concurrent sender retries idempotent.
        await db.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO "QueuedMessages" ("RecipientId", "SenderId", "MessageId", "GroupId", "EncryptedBody", "CreatedAt", "ExpiresAt")
            VALUES ({recipientId}, {senderId}, {messageId}, {groupId}, {encryptedBody}, {now}, {expiresAt})
            ON CONFLICT ("RecipientId", "SenderId", "MessageId") DO NOTHING
            """, cancellationToken);
        return await db.QueuedMessages.AsNoTracking().SingleAsync(m =>
            m.RecipientId == recipientId && m.SenderId == senderId && m.MessageId == messageId, cancellationToken);
    }

    // Retain the legacy method name for callers; fetching no longer removes messages.
    public async Task<List<DequeuedMessage>> DequeueAsync(Guid recipientId, CancellationToken cancellationToken = default)
    {
        var now = DateTimeOffset.UtcNow;
        await db.QueuedMessages.Where(m => m.RecipientId == recipientId && m.ExpiresAt <= now)
            .ExecuteDeleteAsync(cancellationToken);
        return await db.QueuedMessages.AsNoTracking()
            .Where(m => m.RecipientId == recipientId && m.AcknowledgedAt == null && m.ExpiresAt > now)
            .OrderBy(m => m.CreatedAt).ThenBy(m => m.Id)
            .Select(m => new DequeuedMessage { Id = m.Id, MessageId = m.MessageId,
                SenderId = m.SenderId, GroupId = m.GroupId, EncryptedBody = m.EncryptedBody, CreatedAt = m.CreatedAt })
            .ToListAsync(cancellationToken);
    }

    public Task<int> AcknowledgeAsync(Guid recipientId, Guid senderId, Guid messageId,
        CancellationToken cancellationToken = default)
    {
        // Ciphertext is removed only on recipient acknowledgement. Keep a small
        // receipt until TTL so a sender retry cannot resurrect delivered content.
        return db.QueuedMessages.Where(m => m.RecipientId == recipientId && m.SenderId == senderId
                && m.MessageId == messageId && m.AcknowledgedAt == null)
            .ExecuteUpdateAsync(setters => setters.SetProperty(m => m.AcknowledgedAt, DateTimeOffset.UtcNow)
                .SetProperty(m => m.EncryptedBody, Array.Empty<byte>()), cancellationToken);
    }
}
