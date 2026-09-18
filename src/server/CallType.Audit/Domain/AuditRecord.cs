// ---------------------------------------------------------------------------
// AuditRecord.cs — one archived message's metadata (KB3)
// ---------------------------------------------------------------------------
// Written exactly once per MessageId (enforced by a unique index in
// AuditDbContext, not here — DB-level uniqueness is what actually protects
// against a retried ACK double-archiving a message). PrevHash/Hash form the
// per-organization hash chain (see CallType.Audit.Application.HashChain);
// Sequence is the per-organization monotonically increasing position in
// that chain.
//
// Plaintext is never stored: ContentHash is SHA-256 of the plaintext,
// computed once in the archiver's memory and immediately discarded (E03).
// CiphertextForArchive stays null for ArchiveLevel.Metadata; it only gets a
// value once E03b (ArchiveLevel.Full) exists.
// ---------------------------------------------------------------------------

namespace CallType.Audit.Domain;

public class AuditRecord
{
    public long Id { get; private set; }
    public Guid OrganizationId { get; private set; }
    public Guid GroupId { get; private set; }
    public Guid MessageId { get; private set; }
    public Guid SenderDeviceId { get; private set; }
    public DateTimeOffset SentAt { get; private set; }
    public DateTimeOffset ArchivedAt { get; private set; }

    /// <summary>"text" | "attachment" | "call-metadata" — the closed set is E03's to define.</summary>
    public string Kind { get; private set; } = string.Empty;

    public long SizeBytes { get; private set; }
    public byte[] ContentHash { get; private set; } = [];
    public byte[]? CiphertextForArchive { get; private set; }
    public long Sequence { get; private set; }
    public byte[] PrevHash { get; private set; } = [];
    public byte[] Hash { get; private set; } = [];

    private AuditRecord()
    {
    } // EF Core

    public AuditRecord(Guid organizationId, Guid groupId, Guid messageId, Guid senderDeviceId,
        DateTimeOffset sentAt, DateTimeOffset archivedAt, string kind, long sizeBytes, byte[] contentHash,
        byte[]? ciphertextForArchive, long sequence, byte[] prevHash, byte[] hash)
    {
        OrganizationId = organizationId;
        GroupId = groupId;
        MessageId = messageId;
        SenderDeviceId = senderDeviceId;
        SentAt = sentAt;
        ArchivedAt = archivedAt;
        Kind = kind;
        SizeBytes = sizeBytes;
        ContentHash = contentHash;
        CiphertextForArchive = ciphertextForArchive;
        Sequence = sequence;
        PrevHash = prevHash;
        Hash = hash;
    }
}
