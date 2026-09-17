// ---------------------------------------------------------------------------
// AuditDbContextFactory.cs — design-time factory for `dotnet ef migrations`
// ---------------------------------------------------------------------------
// CallType.Audit is a class library with no Program.cs of its own, and
// Business mode may be entirely disabled (no ConnectionStrings:Audit
// configured) in whatever host would otherwise supply this DbContext via DI.
// This factory lets `dotnet ef migrations add --project CallType.Audit` work
// standalone, without a --startup-project. The connection string below is
// only used to generate migrations — it is never used at runtime.
// ---------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace CallType.Audit.Infrastructure;

public class AuditDbContextFactory : IDesignTimeDbContextFactory<AuditDbContext>
{
    public AuditDbContext CreateDbContext(string[] args)
    {
        var optionsBuilder = new DbContextOptionsBuilder<AuditDbContext>();
        optionsBuilder.UseNpgsql("Host=localhost;Port=5432;Database=calltype_audit;Username=postgres;Password=postgres");
        return new AuditDbContext(optionsBuilder.Options);
    }
}
