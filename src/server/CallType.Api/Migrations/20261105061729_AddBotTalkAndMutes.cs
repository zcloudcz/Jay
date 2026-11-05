using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddBotTalkAndMutes : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<List<Guid>>(
                name: "BotTalkAllowedBotDeviceIds",
                table: "Groups",
                type: "uuid[]",
                nullable: false,
                defaultValueSql: "'{}'::uuid[]");

            migrationBuilder.AddColumn<int>(
                name: "BotTalkMaxBotTurns",
                table: "Groups",
                type: "integer",
                nullable: false,
                defaultValue: 5);

            migrationBuilder.AddColumn<string>(
                name: "BotTalkMode",
                table: "Groups",
                type: "character varying(10)",
                maxLength: 10,
                nullable: false,
                defaultValue: "off");

            migrationBuilder.AddColumn<int>(
                name: "BotTalkPauseMinutes",
                table: "Groups",
                type: "integer",
                nullable: false,
                defaultValue: 30);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "BotTalkUpdatedAt",
                table: "Groups",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "BotTalkUpdatedBy",
                table: "Groups",
                type: "uuid",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "ConversationMutes",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    DeviceId = table.Column<Guid>(type: "uuid", nullable: false),
                    GroupId = table.Column<Guid>(type: "uuid", nullable: true),
                    PeerPrimaryDeviceId = table.Column<Guid>(type: "uuid", nullable: true),
                    Mode = table.Column<string>(type: "character varying(5)", maxLength: 5, nullable: false),
                    Until = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ConversationMutes", x => x.Id);
                    table.CheckConstraint("CK_ConversationMutes_OneTarget", "(\"GroupId\" IS NULL) <> (\"PeerPrimaryDeviceId\" IS NULL)");
                    table.ForeignKey(
                        name: "FK_ConversationMutes_Devices_DeviceId",
                        column: x => x.DeviceId,
                        principalTable: "Devices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_ConversationMutes_Devices_PeerPrimaryDeviceId",
                        column: x => x.PeerPrimaryDeviceId,
                        principalTable: "Devices",
                        principalColumn: "DeviceId",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_ConversationMutes_Groups_GroupId",
                        column: x => x.GroupId,
                        principalTable: "Groups",
                        principalColumn: "GroupId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_ConversationMutes_DeviceId_GroupId",
                table: "ConversationMutes",
                columns: new[] { "DeviceId", "GroupId" },
                unique: true,
                filter: "\"GroupId\" IS NOT NULL");

            migrationBuilder.CreateIndex(
                name: "IX_ConversationMutes_DeviceId_PeerPrimaryDeviceId",
                table: "ConversationMutes",
                columns: new[] { "DeviceId", "PeerPrimaryDeviceId" },
                unique: true,
                filter: "\"PeerPrimaryDeviceId\" IS NOT NULL");

            migrationBuilder.CreateIndex(
                name: "IX_ConversationMutes_GroupId",
                table: "ConversationMutes",
                column: "GroupId");

            migrationBuilder.CreateIndex(
                name: "IX_ConversationMutes_PeerPrimaryDeviceId",
                table: "ConversationMutes",
                column: "PeerPrimaryDeviceId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "ConversationMutes");

            migrationBuilder.DropColumn(
                name: "BotTalkAllowedBotDeviceIds",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "BotTalkMaxBotTurns",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "BotTalkMode",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "BotTalkPauseMinutes",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "BotTalkUpdatedAt",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "BotTalkUpdatedBy",
                table: "Groups");
        }
    }
}
