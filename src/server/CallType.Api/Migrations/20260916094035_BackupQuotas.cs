using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class BackupQuotas : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Backups_AccountId",
                table: "Backups");

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ReservationExpiresAt",
                table: "Backups",
                type: "timestamp with time zone",
                nullable: true);

            // Existing rows predate the reservation state machine — they were
            // all synchronously uploaded, so they are backfilled as Completed
            // rather than defaulting to an invalid empty string.
            migrationBuilder.AddColumn<string>(
                name: "Status",
                table: "Backups",
                type: "character varying(20)",
                maxLength: 20,
                nullable: false,
                defaultValue: "Completed");

            migrationBuilder.CreateIndex(
                name: "IX_Backups_AccountId_Status",
                table: "Backups",
                columns: new[] { "AccountId", "Status" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Backups_AccountId_Status",
                table: "Backups");

            migrationBuilder.DropColumn(
                name: "ReservationExpiresAt",
                table: "Backups");

            migrationBuilder.DropColumn(
                name: "Status",
                table: "Backups");

            migrationBuilder.CreateIndex(
                name: "IX_Backups_AccountId",
                table: "Backups",
                column: "AccountId");
        }
    }
}
