using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddUserBlocksAndReports : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "UserBlocks",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    BlockerPrimaryId = table.Column<Guid>(type: "uuid", nullable: false),
                    BlockedPrimaryId = table.Column<Guid>(type: "uuid", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_UserBlocks", x => x.Id);
                    table.ForeignKey(
                        name: "FK_UserBlocks_Devices_BlockedPrimaryId",
                        column: x => x.BlockedPrimaryId,
                        principalTable: "Devices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_UserBlocks_Devices_BlockerPrimaryId",
                        column: x => x.BlockerPrimaryId,
                        principalTable: "Devices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "UserReports",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    ReporterDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    ReportedPrimaryId = table.Column<Guid>(type: "uuid", nullable: false),
                    ReportedHandle = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    GroupId = table.Column<Guid>(type: "uuid", nullable: true),
                    Category = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    Reason = table.Column<string>(type: "character varying(1000)", maxLength: 1000, nullable: false),
                    EvidenceJson = table.Column<string>(type: "text", nullable: false),
                    ContactEmail = table.Column<string>(type: "character varying(254)", maxLength: 254, nullable: true),
                    GoodFaith = table.Column<bool>(type: "boolean", nullable: false),
                    Status = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ResolvedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_UserReports", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_UserBlocks_BlockedPrimaryId",
                table: "UserBlocks",
                column: "BlockedPrimaryId");

            migrationBuilder.CreateIndex(
                name: "IX_UserBlocks_BlockerPrimaryId_BlockedPrimaryId",
                table: "UserBlocks",
                columns: new[] { "BlockerPrimaryId", "BlockedPrimaryId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_UserReports_ReportedPrimaryId",
                table: "UserReports",
                column: "ReportedPrimaryId");

            migrationBuilder.CreateIndex(
                name: "IX_UserReports_ReporterDeviceId_CreatedAt",
                table: "UserReports",
                columns: new[] { "ReporterDeviceId", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_UserReports_Status_CreatedAt",
                table: "UserReports",
                columns: new[] { "Status", "CreatedAt" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "UserBlocks");

            migrationBuilder.DropTable(
                name: "UserReports");
        }
    }
}
