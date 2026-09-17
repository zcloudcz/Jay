using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace CallType.Audit.Migrations
{
    /// <inheritdoc />
    public partial class InitialAudit : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "AdminAuditEvents",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    ActorAccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    EventType = table.Column<string>(type: "character varying(50)", maxLength: 50, nullable: false),
                    DetailsJson = table.Column<string>(type: "text", nullable: false),
                    OccurredAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    Sequence = table.Column<long>(type: "bigint", nullable: false),
                    PrevHash = table.Column<byte[]>(type: "bytea", maxLength: 32, nullable: false),
                    Hash = table.Column<byte[]>(type: "bytea", maxLength: 32, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AdminAuditEvents", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "AuditAccessLogs",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    RequestId = table.Column<Guid>(type: "uuid", nullable: false),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    AccessorAccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    What = table.Column<string>(type: "character varying(500)", maxLength: 500, nullable: false),
                    AccessedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AuditAccessLogs", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "AuditAccessRequests",
                columns: table => new
                {
                    RequestId = table.Column<Guid>(type: "uuid", nullable: false),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    RequesterAccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    Scope = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    Reason = table.Column<string>(type: "character varying(1000)", maxLength: 1000, nullable: false),
                    RequestedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ApproverAccountId = table.Column<Guid>(type: "uuid", nullable: true),
                    ApprovedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    RejectedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    WindowExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AuditAccessRequests", x => x.RequestId);
                });

            migrationBuilder.CreateTable(
                name: "AuditRecords",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    GroupId = table.Column<Guid>(type: "uuid", nullable: false),
                    MessageId = table.Column<Guid>(type: "uuid", nullable: false),
                    SenderDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    SentAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ArchivedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    Kind = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    SizeBytes = table.Column<long>(type: "bigint", nullable: false),
                    ContentHash = table.Column<byte[]>(type: "bytea", maxLength: 32, nullable: false),
                    CiphertextForArchive = table.Column<byte[]>(type: "bytea", nullable: true),
                    Sequence = table.Column<long>(type: "bigint", nullable: false),
                    PrevHash = table.Column<byte[]>(type: "bytea", maxLength: 32, nullable: false),
                    Hash = table.Column<byte[]>(type: "bytea", maxLength: 32, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AuditRecords", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "DailyRoots",
                columns: table => new
                {
                    Day = table.Column<DateOnly>(type: "date", nullable: false),
                    RootHash = table.Column<byte[]>(type: "bytea", maxLength: 32, nullable: false),
                    TimestampToken = table.Column<byte[]>(type: "bytea", nullable: true),
                    TsaName = table.Column<string>(type: "text", nullable: true),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_DailyRoots", x => x.Day);
                });

            migrationBuilder.CreateTable(
                name: "EmergencyDrills",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    StartedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    CompletedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ConfirmedMemberCount = table.Column<int>(type: "integer", nullable: false),
                    ResponseTime = table.Column<TimeSpan>(type: "interval", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmergencyDrills", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "EmergencyKits",
                columns: table => new
                {
                    KitId = table.Column<Guid>(type: "uuid", nullable: false),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    RecoveryCodeHash = table.Column<string>(type: "text", nullable: false),
                    IssuedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    RevokedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmergencyKits", x => x.KitId);
                });

            migrationBuilder.CreateTable(
                name: "Organizations",
                columns: table => new
                {
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    Name = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ArchivePublicKey = table.Column<byte[]>(type: "bytea", nullable: true),
                    RetentionDays = table.Column<int>(type: "integer", nullable: false),
                    AuditorDeviceId = table.Column<Guid>(type: "uuid", nullable: true),
                    ArchiveLevel = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Organizations", x => x.OrganizationId);
                });

            migrationBuilder.CreateTable(
                name: "OrgDailyProofs",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    Day = table.Column<DateOnly>(type: "date", nullable: false),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    ProofPath = table.Column<byte[]>(type: "bytea", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OrgDailyProofs", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "OrgEnrollments",
                columns: table => new
                {
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    DeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    AccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    EnrolledAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    RevokedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OrgEnrollments", x => new { x.OrganizationId, x.DeviceId });
                });

            migrationBuilder.CreateTable(
                name: "OrgInvites",
                columns: table => new
                {
                    InviteId = table.Column<Guid>(type: "uuid", nullable: false),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    Code = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    IssuedByAccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    IssuedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    UsedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OrgInvites", x => x.InviteId);
                });

            migrationBuilder.CreateTable(
                name: "OrgMembers",
                columns: table => new
                {
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    AccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    Role = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    AddedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    RemovedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OrgMembers", x => new { x.OrganizationId, x.AccountId });
                    table.ForeignKey(
                        name: "FK_OrgMembers_Organizations_OrganizationId",
                        column: x => x.OrganizationId,
                        principalTable: "Organizations",
                        principalColumn: "OrganizationId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_AdminAuditEvents_OrganizationId_Sequence",
                table: "AdminAuditEvents",
                columns: new[] { "OrganizationId", "Sequence" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_AuditAccessLogs_RequestId",
                table: "AuditAccessLogs",
                column: "RequestId");

            migrationBuilder.CreateIndex(
                name: "IX_AuditAccessRequests_OrganizationId",
                table: "AuditAccessRequests",
                column: "OrganizationId");

            migrationBuilder.CreateIndex(
                name: "IX_AuditRecords_OrganizationId_MessageId",
                table: "AuditRecords",
                columns: new[] { "OrganizationId", "MessageId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_AuditRecords_OrganizationId_Sequence",
                table: "AuditRecords",
                columns: new[] { "OrganizationId", "Sequence" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_EmergencyDrills_OrganizationId",
                table: "EmergencyDrills",
                column: "OrganizationId");

            migrationBuilder.CreateIndex(
                name: "IX_EmergencyKits_OrganizationId",
                table: "EmergencyKits",
                column: "OrganizationId");

            migrationBuilder.CreateIndex(
                name: "IX_OrgDailyProofs_OrganizationId_Day",
                table: "OrgDailyProofs",
                columns: new[] { "OrganizationId", "Day" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_OrgInvites_Code",
                table: "OrgInvites",
                column: "Code",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AdminAuditEvents");

            migrationBuilder.DropTable(
                name: "AuditAccessLogs");

            migrationBuilder.DropTable(
                name: "AuditAccessRequests");

            migrationBuilder.DropTable(
                name: "AuditRecords");

            migrationBuilder.DropTable(
                name: "DailyRoots");

            migrationBuilder.DropTable(
                name: "EmergencyDrills");

            migrationBuilder.DropTable(
                name: "EmergencyKits");

            migrationBuilder.DropTable(
                name: "OrgDailyProofs");

            migrationBuilder.DropTable(
                name: "OrgEnrollments");

            migrationBuilder.DropTable(
                name: "OrgInvites");

            migrationBuilder.DropTable(
                name: "OrgMembers");

            migrationBuilder.DropTable(
                name: "Organizations");
        }
    }
}
