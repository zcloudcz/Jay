using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class GapClosureWave1 : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<byte[]>(
                name: "PushKey",
                table: "Devices",
                type: "bytea",
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "PushTokenUpdatedAt",
                table: "Devices",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "SignedPreKeyId",
                table: "Devices",
                type: "integer",
                nullable: false,
                defaultValue: 1);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "SignedPreKeyUpdatedAt",
                table: "Devices",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "VoipPushEnvironment",
                table: "Devices",
                type: "character varying(10)",
                maxLength: 10,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "VoipPushToken",
                table: "Devices",
                type: "character varying(200)",
                maxLength: 200,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "E2eAttachments",
                columns: table => new
                {
                    BlobId = table.Column<Guid>(type: "uuid", nullable: false),
                    UploaderDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    SizeBytes = table.Column<long>(type: "bigint", nullable: false),
                    ChunkSizeBytes = table.Column<int>(type: "integer", nullable: false),
                    ChunkCount = table.Column<int>(type: "integer", nullable: false),
                    Status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    CommittedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_E2eAttachments", x => x.BlobId);
                });

            migrationBuilder.AddCheckConstraint(
                name: "CK_Devices_PushKey_Length",
                table: "Devices",
                sql: "\"PushKey\" IS NULL OR octet_length(\"PushKey\") = 32");

            migrationBuilder.CreateIndex(
                name: "IX_E2eAttachments_CreatedAt",
                table: "E2eAttachments",
                column: "CreatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_E2eAttachments_Status_ExpiresAt",
                table: "E2eAttachments",
                columns: new[] { "Status", "ExpiresAt" });

            migrationBuilder.CreateIndex(
                name: "IX_E2eAttachments_UploaderDeviceId_CreatedAt",
                table: "E2eAttachments",
                columns: new[] { "UploaderDeviceId", "CreatedAt" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "E2eAttachments");

            migrationBuilder.DropCheckConstraint(
                name: "CK_Devices_PushKey_Length",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "PushKey",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "PushTokenUpdatedAt",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "SignedPreKeyId",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "SignedPreKeyUpdatedAt",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "VoipPushEnvironment",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "VoipPushToken",
                table: "Devices");
        }
    }
}
