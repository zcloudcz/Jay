using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddMediaUploads : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "MediaUploads",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    UploaderDeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    SizeBytes = table.Column<long>(type: "bigint", nullable: false),
                    ChunkSize = table.Column<int>(type: "integer", nullable: false),
                    Status = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    CompletedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaUploads", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_MediaUploads_ExpiresAt",
                table: "MediaUploads",
                column: "ExpiresAt");

            migrationBuilder.CreateIndex(
                name: "IX_MediaUploads_UploaderDeviceId_CreatedAt",
                table: "MediaUploads",
                columns: new[] { "UploaderDeviceId", "CreatedAt" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "MediaUploads");
        }
    }
}
