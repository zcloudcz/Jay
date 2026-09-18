using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace CallType.Audit.Migrations
{
    /// <inheritdoc />
    public partial class EmergencyChannel : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "Label",
                table: "EmergencyKits",
                type: "character varying(200)",
                maxLength: 200,
                nullable: false,
                defaultValue: "");

            migrationBuilder.CreateTable(
                name: "EmergencyDrillConfirmations",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    DrillId = table.Column<long>(type: "bigint", nullable: false),
                    DeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    ConfirmedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmergencyDrillConfirmations", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "EmergencyEnrollmentCodes",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    KitId = table.Column<Guid>(type: "uuid", nullable: false),
                    OrganizationId = table.Column<Guid>(type: "uuid", nullable: false),
                    CodeHash = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    UsedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    UsedByDeviceId = table.Column<Guid>(type: "uuid", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmergencyEnrollmentCodes", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_EmergencyDrillConfirmations_DrillId_DeviceId",
                table: "EmergencyDrillConfirmations",
                columns: new[] { "DrillId", "DeviceId" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_EmergencyEnrollmentCodes_CodeHash",
                table: "EmergencyEnrollmentCodes",
                column: "CodeHash",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_EmergencyEnrollmentCodes_KitId",
                table: "EmergencyEnrollmentCodes",
                column: "KitId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "EmergencyDrillConfirmations");

            migrationBuilder.DropTable(
                name: "EmergencyEnrollmentCodes");

            migrationBuilder.DropColumn(
                name: "Label",
                table: "EmergencyKits");
        }
    }
}
