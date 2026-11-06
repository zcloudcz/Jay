// ---------------------------------------------------------------------------
// AppDbContext.cs — EF Core database context for CallType
// ---------------------------------------------------------------------------
// Configures all entity mappings, indexes, and constraints. The schema is
// designed for an E2E encrypted messenger where the server never sees
// plaintext — encrypted fields are stored as opaque byte arrays.
//
// Key design decisions in OnModelCreating:
// - Composite PKs on join tables (AccountDevice, GroupMember) to prevent
//   duplicate memberships without extra unique indexes.
// - Unique index on OneTimePreKey (DeviceId, KeyId) so the X3DH protocol
//   can reference keys by client-assigned ID without collisions.
// - Covering index on QueuedMessage (RecipientId, CreatedAt) for the
//   "fetch my pending messages" hot path.
// - DateTimeOffset columns map to 'timestamp with time zone' (Npgsql native
//   mapping) so there is no timezone ambiguity.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Api.Models;

namespace CallType.Api.Data;

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<OneTimePreKey> OneTimePreKeys => Set<OneTimePreKey>();
    public DbSet<Account> Accounts => Set<Account>();
    public DbSet<AccountDevice> AccountDevices => Set<AccountDevice>();
    public DbSet<DeviceList> DeviceLists => Set<DeviceList>();
    public DbSet<DeviceListMember> DeviceListMembers => Set<DeviceListMember>();
    public DbSet<QueuedMessage> QueuedMessages => Set<QueuedMessage>();
    public DbSet<Group> Groups => Set<Group>();
    public DbSet<GroupMember> GroupMembers => Set<GroupMember>();
    public DbSet<ConversationMute> ConversationMutes => Set<ConversationMute>();
    public DbSet<Backup> Backups => Set<Backup>();
    public DbSet<Channel> Channels => Set<Channel>();
    public DbSet<ChannelAdmin> ChannelAdmins => Set<ChannelAdmin>();
    public DbSet<ChannelPost> ChannelPosts => Set<ChannelPost>();
    public DbSet<ChannelFollower> ChannelFollowers => Set<ChannelFollower>();
    public DbSet<ChannelReaction> ChannelReactions => Set<ChannelReaction>();
    public DbSet<ChannelPollVote> ChannelPollVotes => Set<ChannelPollVote>();
    public DbSet<ChannelReport> ChannelReports => Set<ChannelReport>();
    public DbSet<ModerationDecision> ModerationDecisions => Set<ModerationDecision>();
    public DbSet<AccountMfa> AccountMfas => Set<AccountMfa>();
    public DbSet<AccountMfaBackupCode> AccountMfaBackupCodes => Set<AccountMfaBackupCode>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // -----------------------------------------------------------------
        // Device
        // -----------------------------------------------------------------
        modelBuilder.Entity<Device>(entity =>
        {
            entity.HasKey(d => d.DeviceId);

            // UserHandle must be unique — it is the public discovery identifier.
            // Format is "CT-XXXX-XXXX" (12 chars) where X is alphanumeric.
            entity.Property(d => d.UserHandle).HasMaxLength(12);
            entity.HasIndex(d => d.UserHandle).IsUnique();

            entity.Property(d => d.PushPlatform).HasMaxLength(10);
            entity.Property(d => d.PushLocale).HasMaxLength(16);
            entity.Property(d => d.VoipPushToken).HasMaxLength(200);
            entity.Property(d => d.DisplayName).HasMaxLength(60);
        });

        // -----------------------------------------------------------------
        // OneTimePreKey
        // -----------------------------------------------------------------
        modelBuilder.Entity<OneTimePreKey>(entity =>
        {
            entity.HasKey(k => k.Id);

            // Auto-increment for the server-side surrogate key.
            entity.Property(k => k.Id).ValueGeneratedOnAdd();

            // The X3DH spec requires the (DeviceId, KeyId) pair to be unique
            // so that the initiator can unambiguously reference which key it used.
            entity.HasIndex(k => new { k.DeviceId, k.KeyId }).IsUnique();

            entity.HasOne(k => k.Device)
                  .WithMany(d => d.OneTimePreKeys)
                  .HasForeignKey(k => k.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // Account
        // -----------------------------------------------------------------
        modelBuilder.Entity<Account>(entity =>
        {
            entity.HasKey(a => a.AccountId);

            // Email is the only PII — unique constraint enables login lookups.
            entity.Property(a => a.Email).HasMaxLength(255);
            entity.HasIndex(a => a.Email).IsUnique();
        });

        // -----------------------------------------------------------------
        // AccountMfa / AccountMfaBackupCode (N03a) — cascade on Account delete
        // so GDPR account deletion (N09) needs no extra code here.
        // -----------------------------------------------------------------
        modelBuilder.Entity<AccountMfa>(entity =>
        {
            entity.HasKey(m => m.AccountId);

            entity.HasOne(m => m.Account)
                  .WithOne()
                  .HasForeignKey<AccountMfa>(m => m.AccountId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<AccountMfaBackupCode>(entity =>
        {
            entity.HasKey(c => c.Id);

            entity.HasOne(c => c.AccountMfa)
                  .WithMany(m => m.BackupCodes)
                  .HasForeignKey(c => c.AccountId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // AccountDevice — join table with composite PK
        // -----------------------------------------------------------------
        modelBuilder.Entity<AccountDevice>(entity =>
        {
            // Composite PK prevents the same device being linked to the same
            // account twice, without needing a separate unique index.
            entity.HasKey(ad => new { ad.AccountId, ad.DeviceId });

            entity.HasOne(ad => ad.Account)
                  .WithMany(a => a.AccountDevices)
                  .HasForeignKey(ad => ad.AccountId)
                  .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne(ad => ad.Device)
                  .WithMany(d => d.AccountDevices)
                  .HasForeignKey(ad => ad.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // DeviceList / DeviceListMember - multi-device routing
        // -----------------------------------------------------------------
        // Cascades are DB-level on purpose: PrivacyEndpoints deletes a Device
        // with raw SQL, and a deleted companion must disappear from routing
        // (a deleted primary takes the whole list with it).
        modelBuilder.Entity<DeviceList>(entity =>
        {
            entity.HasKey(l => l.PrimaryDeviceId);
            entity.Property(l => l.Version).IsConcurrencyToken();
            entity.HasOne<Device>()
                  .WithOne()
                  .HasForeignKey<DeviceList>(l => l.PrimaryDeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<DeviceListMember>(entity =>
        {
            entity.HasKey(m => m.DeviceId);
            entity.HasIndex(m => m.PrimaryDeviceId);
            entity.HasOne<Device>()
                  .WithOne()
                  .HasForeignKey<DeviceListMember>(m => m.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne<DeviceList>()
                  .WithMany(l => l.Members)
                  .HasForeignKey(m => m.PrimaryDeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // QueuedMessage
        // -----------------------------------------------------------------
        modelBuilder.Entity<QueuedMessage>(entity =>
        {
            entity.HasKey(m => m.Id);
            entity.Property(m => m.Id).ValueGeneratedOnAdd();

            // The most common query is "give me all messages for device X,
            // ordered by arrival time." This composite index covers that
            // query as an index-only scan on RecipientId with CreatedAt sort.
            entity.HasIndex(m => new { m.RecipientId, m.CreatedAt });
            entity.HasIndex(m => new { m.RecipientId, m.SenderId, m.MessageId }).IsUnique();
        });

        // -----------------------------------------------------------------
        // Group
        // -----------------------------------------------------------------
        modelBuilder.Entity<Group>(entity =>
        {
            entity.HasKey(g => g.GroupId);

            // Business mode (plan §1): "which groups belong to organization X"
            // backs E02's revocation flow (remove a device from all its
            // organization's groups) and admin listing. Sparse in practice —
            // most groups are anonymous and this column is null.
            entity.HasIndex(g => g.OrganizationId);

            // Bot conversation setting as plain columns of Groups (owned type,
            // table splitting): always read together with the group, one row
            // per group, so a separate table would only add a join. Defaults
            // live in the DB too so the migration fills existing groups with
            // "off" without a data step. Sentinel -1 (never a valid value)
            // makes EF always send the int: with the CLR default 0 as the
            // sentinel, a legitimate PauseMinutes = 0 would be swapped for
            // the DB default 30 on insert.
            entity.OwnsOne(g => g.BotTalk, bt =>
            {
                bt.Property(b => b.Mode).HasColumnName("BotTalkMode").HasMaxLength(10)
                  .HasDefaultValue(GroupBotTalk.ModeOff);
                bt.Property(b => b.AllowedBotDeviceIds).HasColumnName("BotTalkAllowedBotDeviceIds")
                  .HasDefaultValueSql("'{}'::uuid[]");
                bt.Property(b => b.MaxBotTurns).HasColumnName("BotTalkMaxBotTurns")
                  .HasDefaultValue(GroupBotTalk.DefaultMaxBotTurns).HasSentinel(-1);
                bt.Property(b => b.PauseMinutes).HasColumnName("BotTalkPauseMinutes")
                  .HasDefaultValue(GroupBotTalk.DefaultPauseMinutes).HasSentinel(-1);
                bt.Property(b => b.UpdatedBy).HasColumnName("BotTalkUpdatedBy");
                bt.Property(b => b.UpdatedAt).HasColumnName("BotTalkUpdatedAt");
            });
            // Required: without it EF treats an owned type whose columns all
            // hold defaults as "maybe absent" and could materialize null.
            entity.Navigation(g => g.BotTalk).IsRequired();
        });

        // -----------------------------------------------------------------
        // ConversationMute - per-device mute of a group or 1:1 (push skip)
        // -----------------------------------------------------------------
        modelBuilder.Entity<ConversationMute>(entity =>
        {
            entity.HasKey(m => m.Id);
            entity.Property(m => m.Id).ValueGeneratedOnAdd();
            entity.Property(m => m.Mode).HasMaxLength(5);

            // One mute per (device, conversation). Partial unique indexes
            // because Postgres treats NULLs as distinct; they double as the
            // lookup index of the push hot path (DeviceId IN (...) AND GroupId = x).
            entity.HasIndex(m => new { m.DeviceId, m.GroupId }).IsUnique()
                  .HasFilter("\"GroupId\" IS NOT NULL");
            entity.HasIndex(m => new { m.DeviceId, m.PeerPrimaryDeviceId }).IsUnique()
                  .HasFilter("\"PeerPrimaryDeviceId\" IS NOT NULL");
            entity.ToTable(t => t.HasCheckConstraint("CK_ConversationMutes_OneTarget",
                "(\"GroupId\" IS NULL) <> (\"PeerPrimaryDeviceId\" IS NULL)"));

            // DB-level cascades (like DeviceList): PrivacyEndpoints deletes
            // devices with raw SQL, and a deleted group or device must not
            // leave mutes behind.
            entity.HasOne<Device>().WithMany().HasForeignKey(m => m.DeviceId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne<Device>().WithMany().HasForeignKey(m => m.PeerPrimaryDeviceId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne<Group>().WithMany().HasForeignKey(m => m.GroupId).OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // GroupMember — join table with composite PK
        // -----------------------------------------------------------------
        modelBuilder.Entity<GroupMember>(entity =>
        {
            // Per-device membership (not per-account) because each device
            // has its own key material for the group session.
            entity.HasKey(gm => new { gm.GroupId, gm.DeviceId });

            entity.Property(gm => gm.Role).HasMaxLength(10).HasDefaultValue("member");

            entity.HasOne(gm => gm.Group)
                  .WithMany(g => g.Members)
                  .HasForeignKey(gm => gm.GroupId)
                  .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne(gm => gm.Device)
                  .WithMany(d => d.GroupMemberships)
                  .HasForeignKey(gm => gm.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // Backup
        // -----------------------------------------------------------------
        modelBuilder.Entity<Backup>(entity =>
        {
            entity.HasKey(b => b.Id);
            entity.Property(b => b.Id).ValueGeneratedOnAdd();

            // Stored as text (not the numeric enum default) so the DB value is
            // readable when debugging quota issues directly in PostgreSQL.
            entity.Property(b => b.Status).HasConversion<string>().HasMaxLength(20);

            // Quota checks always filter/sum by AccountId + Status — cover it.
            entity.HasIndex(b => new { b.AccountId, b.Status });

            entity.HasOne(b => b.Account)
                  .WithMany(a => a.Backups)
                  .HasForeignKey(b => b.AccountId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        // -----------------------------------------------------------------
        // Channels — public one-way broadcast (plaintext by design, see Channel.cs)
        // -----------------------------------------------------------------
        // Device references in the channel tables (admin, follower, reaction,
        // vote, reporter) cascade from Device where a row is meaningless without
        // it, but have no navigation on Device on purpose: nothing should be able
        // to walk from a device to "what it follows / reacted to" by accident.
        modelBuilder.Entity<Channel>(entity =>
        {
            entity.HasKey(c => c.ChannelId);

            // "CH-XXXX-XXXX" — same shape as Device.UserHandle.
            entity.Property(c => c.Handle).HasMaxLength(12);
            entity.HasIndex(c => c.Handle).IsUnique();

            entity.Property(c => c.Name).HasMaxLength(64);
            entity.Property(c => c.Description).HasMaxLength(512);

            // "Channels owned by this account" backs the MaxOwnedPerDevice limit
            // check on create and the owned part of GET /channels/mine.
            entity.HasIndex(c => c.OwnerAccountId);

            // Restrict, not Cascade: deleting an account must not silently wipe
            // a public channel and its followers — that has to be an explicit step.
            entity.HasOne(c => c.OwnerAccount)
                  .WithMany()
                  .HasForeignKey(c => c.OwnerAccountId)
                  .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<ChannelAdmin>(entity =>
        {
            entity.HasKey(a => new { a.ChannelId, a.DeviceId });

            entity.Property(a => a.Role).HasMaxLength(10).HasDefaultValue("admin");

            entity.HasOne(a => a.Channel)
                  .WithMany(c => c.Admins)
                  .HasForeignKey(a => a.ChannelId)
                  .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne<Device>()
                  .WithMany()
                  .HasForeignKey(a => a.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ChannelPost>(entity =>
        {
            // PostId is client-generated (idempotent publish) — never ValueGeneratedOnAdd.
            entity.HasKey(p => p.PostId);
            entity.Property(p => p.PostId).ValueGeneratedNever();

            // Stored as text like Backup.Status: readable in psql, and the enum
            // (no Video member) is the single place that limits the allowed kinds.
            entity.Property(p => p.Kind).HasConversion<string>().HasMaxLength(10);
            entity.Property(p => p.Body).HasMaxLength(4096);
            entity.Property(p => p.AttachmentBlobPath).HasMaxLength(256);

            // Feed paging: "posts of channel X, newest first, before <ts>".
            entity.HasIndex(p => new { p.ChannelId, p.CreatedAt }).IsDescending(false, true);

            // Retention cleanup scans by age across ALL channels, which the
            // composite index above (leading ChannelId) cannot serve.
            entity.HasIndex(p => p.CreatedAt);

            entity.HasOne(p => p.Channel)
                  .WithMany(c => c.Posts)
                  .HasForeignKey(p => p.ChannelId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ChannelFollower>(entity =>
        {
            entity.HasKey(f => new { f.ChannelId, f.DeviceId });

            // "My channels" looks up by DeviceId, which is the second PK column
            // and therefore not usable from the PK index.
            entity.HasIndex(f => f.DeviceId);

            // WARNING for a future device-deletion feature: the Device FK below
            // cascades, which removes follower rows behind ChannelService's back
            // and leaves Channel.FollowerCount too high. Whoever adds device
            // deletion must decrement (or recount) FollowerCount in the same
            // transaction. No device is ever deleted today.
            entity.HasOne(f => f.Channel)
                  .WithMany(c => c.Followers)
                  .HasForeignKey(f => f.ChannelId)
                  .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne<Device>()
                  .WithMany()
                  .HasForeignKey(f => f.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ChannelReaction>(entity =>
        {
            entity.HasKey(r => new { r.PostId, r.DeviceId });
            entity.Property(r => r.Emoji).HasMaxLength(16);

            // Cascade from the post so retention's bulk DELETE of posts removes
            // reactions in the database without loading them.
            entity.HasOne(r => r.Post)
                  .WithMany()
                  .HasForeignKey(r => r.PostId)
                  .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne<Device>()
                  .WithMany()
                  .HasForeignKey(r => r.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ChannelPollVote>(entity =>
        {
            entity.HasKey(v => new { v.PostId, v.DeviceId });

            entity.HasOne(v => v.Post)
                  .WithMany()
                  .HasForeignKey(v => v.PostId)
                  .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne<Device>()
                  .WithMany()
                  .HasForeignKey(v => v.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ChannelReport>(entity =>
        {
            entity.HasKey(r => r.Id);
            entity.Property(r => r.Id).ValueGeneratedOnAdd();
            entity.Property(r => r.Reason).HasMaxLength(512);

            // Operator reviews reports per channel. PostId and ReporterDeviceId
            // are plain columns (no FK) so a report survives post retention.
            entity.HasIndex(r => r.ChannelId);

            // DB defaults matter for the rows that exist before the migration
            // (they become open "terms" reports, which is what they were).
            entity.Property(r => r.Category).HasMaxLength(10).HasDefaultValue("terms");
            entity.Property(r => r.Status).HasMaxLength(10).HasDefaultValue("open");
            entity.Property(r => r.ContactEmail).HasMaxLength(254);

            // The operator queue: "open reports, oldest first" and the summary counts.
            entity.HasIndex(r => new { r.Status, r.CreatedAt });

            entity.HasOne(r => r.Channel)
                  .WithMany()
                  .HasForeignKey(r => r.ChannelId)
                  .OnDelete(DeleteBehavior.Cascade);

            // SetNull, not Cascade: removing a decision (never done by the API)
            // must not take the reports with it.
            entity.HasOne(r => r.Decision)
                  .WithMany()
                  .HasForeignKey(r => r.DecisionId)
                  .OnDelete(DeleteBehavior.SetNull);
        });

        modelBuilder.Entity<ModerationDecision>(entity =>
        {
            entity.HasKey(d => d.Id);
            entity.Property(d => d.Id).ValueGeneratedOnAdd();
            entity.Property(d => d.Action).HasMaxLength(20);
            entity.Property(d => d.Ground).HasMaxLength(10);
            entity.Property(d => d.Rule).HasMaxLength(3);
            entity.Property(d => d.LegalGround).HasMaxLength(300);
            entity.Property(d => d.Explanation).HasMaxLength(2000);

            // Statements of one channel, newest first (owner view + case detail).
            entity.HasIndex(d => new { d.ChannelId, d.CreatedAt });

            entity.HasOne(d => d.Channel)
                  .WithMany()
                  .HasForeignKey(d => d.ChannelId)
                  .OnDelete(DeleteBehavior.Cascade);
        });
    }
}
