// ---------------------------------------------------------------------------
// AuditDbContext.cs — EF Core context for the Org & Audit database (plan §3)
// ---------------------------------------------------------------------------
// Physically separate database and credentials from Delivery's AppDbContext
// (KB3 — compromising Delivery must not give access to the archive). Its own
// migrations history table (via HasDefaultSchema / MigrationsHistoryTable is
// unnecessary here since it's a wholly separate database, not schema, but
// its migrations live under this project's own Migrations/ folder and are
// applied with `--context AuditDbContext`, never mixed with AppDbContext's).
//
// Production role model: the app connects with a role that can only
// INSERT/SELECT (no UPDATE/DELETE/TRUNCATE) — see infra/postgres/audit-roles.sql
// for the exact grants and why. EnsureCreatedAsync/MigrateAsync must run
// under a privileged migration role, never the app's own runtime connection.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using CallType.Audit.Application;
using CallType.Audit.Domain;

namespace CallType.Audit.Infrastructure;

public class AuditDbContext(DbContextOptions<AuditDbContext> options) : DbContext(options)
{
    public DbSet<Organization> Organizations => Set<Organization>();
    public DbSet<OrgMember> OrgMembers => Set<OrgMember>();
    public DbSet<OrgEnrollment> OrgEnrollments => Set<OrgEnrollment>();
    public DbSet<OrgInvite> OrgInvites => Set<OrgInvite>();
    public DbSet<AuditRecord> AuditRecords => Set<AuditRecord>();
    public DbSet<AdminAuditEvent> AdminAuditEvents => Set<AdminAuditEvent>();
    public DbSet<AuditAccessRequest> AuditAccessRequests => Set<AuditAccessRequest>();
    public DbSet<AuditAccessLog> AuditAccessLogs => Set<AuditAccessLog>();
    public DbSet<DailyRoot> DailyRoots => Set<DailyRoot>();
    public DbSet<OrgDailyProof> OrgDailyProofs => Set<OrgDailyProof>();
    public DbSet<EmergencyKit> EmergencyKits => Set<EmergencyKit>();
    public DbSet<EmergencyDrill> EmergencyDrills => Set<EmergencyDrill>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // -----------------------------------------------------------------
        // Organization (aggregate root) + OrgMember (child, composite PK)
        // -----------------------------------------------------------------
        modelBuilder.Entity<Organization>(entity =>
        {
            entity.HasKey(o => o.OrganizationId);
            entity.Property(o => o.Name).HasMaxLength(200);
            entity.Property(o => o.ArchiveLevel).HasConversion<string>().HasMaxLength(20);

            // Backing field access: Organization exposes Members as a read-only
            // collection and only mutates it through AddMember/RemoveMember —
            // EF needs to go through the private field, not a (nonexistent) setter.
            entity.HasMany(o => o.Members)
                  .WithOne()
                  .HasForeignKey(m => m.OrganizationId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.Navigation(o => o.Members).UsePropertyAccessMode(PropertyAccessMode.Field);
        });

        modelBuilder.Entity<OrgMember>(entity =>
        {
            // Per-account membership row, not per-device — an account can enroll multiple devices.
            entity.HasKey(m => new { m.OrganizationId, m.AccountId });
            entity.Property(m => m.Role).HasConversion<string>().HasMaxLength(20);
        });

        // -----------------------------------------------------------------
        // OrgEnrollment — device enrolled via invite
        // -----------------------------------------------------------------
        modelBuilder.Entity<OrgEnrollment>(entity =>
        {
            entity.HasKey(e => new { e.OrganizationId, e.DeviceId });
        });

        // -----------------------------------------------------------------
        // OrgInvite — single-use code
        // -----------------------------------------------------------------
        modelBuilder.Entity<OrgInvite>(entity =>
        {
            entity.HasKey(i => i.InviteId);
            entity.Property(i => i.Code).HasMaxLength(64);
            entity.HasIndex(i => i.Code).IsUnique();
        });

        // -----------------------------------------------------------------
        // AuditRecord — hash-chained per organization
        // -----------------------------------------------------------------
        modelBuilder.Entity<AuditRecord>(entity =>
        {
            entity.HasKey(r => r.Id);
            entity.Property(r => r.Id).ValueGeneratedOnAdd();
            entity.Property(r => r.Kind).HasMaxLength(20);
            entity.Property(r => r.ContentHash).HasMaxLength(HashChain.HashLength);
            entity.Property(r => r.PrevHash).HasMaxLength(HashChain.HashLength);
            entity.Property(r => r.Hash).HasMaxLength(HashChain.HashLength);

            // Offline chain verification (E03's audit-verify tool) walks one
            // organization's records in Sequence order — an efficient range
            // scan, not a sort at query time.
            entity.HasIndex(r => new { r.OrganizationId, r.Sequence }).IsUnique();

            // MessageId de-dup: KB2 requires "archived exactly once" even if
            // the ACK-then-retry path runs twice.
            entity.HasIndex(r => new { r.OrganizationId, r.MessageId }).IsUnique();
        });

        // -----------------------------------------------------------------
        // AdminAuditEvent — separate hash chain per organization (KB6)
        // -----------------------------------------------------------------
        modelBuilder.Entity<AdminAuditEvent>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Id).ValueGeneratedOnAdd();
            entity.Property(e => e.EventType).HasMaxLength(50);
            entity.Property(e => e.PrevHash).HasMaxLength(HashChain.HashLength);
            entity.Property(e => e.Hash).HasMaxLength(HashChain.HashLength);

            entity.HasIndex(e => new { e.OrganizationId, e.Sequence }).IsUnique();
        });

        // -----------------------------------------------------------------
        // AuditAccessRequest / AuditAccessLog (KB5)
        // -----------------------------------------------------------------
        modelBuilder.Entity<AuditAccessRequest>(entity =>
        {
            entity.HasKey(r => r.RequestId);
            entity.Property(r => r.Scope).HasMaxLength(200);
            entity.Property(r => r.Reason).HasMaxLength(1000);
            entity.HasIndex(r => r.OrganizationId);
        });

        modelBuilder.Entity<AuditAccessLog>(entity =>
        {
            entity.HasKey(l => l.Id);
            entity.Property(l => l.Id).ValueGeneratedOnAdd();
            entity.Property(l => l.What).HasMaxLength(500);
            entity.HasIndex(l => l.RequestId);
        });

        // -----------------------------------------------------------------
        // DailyRoot / OrgDailyProof (KB4)
        // -----------------------------------------------------------------
        modelBuilder.Entity<DailyRoot>(entity =>
        {
            entity.HasKey(d => d.Day);
            entity.Property(d => d.RootHash).HasMaxLength(HashChain.HashLength);
        });

        modelBuilder.Entity<OrgDailyProof>(entity =>
        {
            entity.HasKey(p => p.Id);
            entity.Property(p => p.Id).ValueGeneratedOnAdd();
            entity.HasIndex(p => new { p.OrganizationId, p.Day }).IsUnique();
        });

        // -----------------------------------------------------------------
        // EmergencyKit / EmergencyDrill (E07)
        // -----------------------------------------------------------------
        modelBuilder.Entity<EmergencyKit>(entity =>
        {
            entity.HasKey(k => k.KitId);
            entity.HasIndex(k => k.OrganizationId);
        });

        modelBuilder.Entity<EmergencyDrill>(entity =>
        {
            entity.HasKey(d => d.Id);
            entity.Property(d => d.Id).ValueGeneratedOnAdd();
            entity.HasIndex(d => d.OrganizationId);
        });
    }
}
