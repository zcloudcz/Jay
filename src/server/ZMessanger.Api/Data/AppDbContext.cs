// ---------------------------------------------------------------------------
// AppDbContext.cs — EF Core database context for ZMessanger
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
using ZMessanger.Api.Models;

namespace ZMessanger.Api.Data;

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<OneTimePreKey> OneTimePreKeys => Set<OneTimePreKey>();
    public DbSet<Account> Accounts => Set<Account>();
    public DbSet<AccountDevice> AccountDevices => Set<AccountDevice>();
    public DbSet<QueuedMessage> QueuedMessages => Set<QueuedMessage>();
    public DbSet<Group> Groups => Set<Group>();
    public DbSet<GroupMember> GroupMembers => Set<GroupMember>();
    public DbSet<Backup> Backups => Set<Backup>();

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
            // Format is "ZM-XXXX-XXXX" (12 chars) where X is alphanumeric.
            entity.Property(d => d.UserHandle).HasMaxLength(12);
            entity.HasIndex(d => d.UserHandle).IsUnique();

            entity.Property(d => d.PushPlatform).HasMaxLength(10);
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
        });

        // -----------------------------------------------------------------
        // Group
        // -----------------------------------------------------------------
        modelBuilder.Entity<Group>(entity =>
        {
            entity.HasKey(g => g.GroupId);
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

            entity.HasOne(b => b.Account)
                  .WithMany(a => a.Backups)
                  .HasForeignKey(b => b.AccountId)
                  .OnDelete(DeleteBehavior.Cascade);
        });
    }
}
