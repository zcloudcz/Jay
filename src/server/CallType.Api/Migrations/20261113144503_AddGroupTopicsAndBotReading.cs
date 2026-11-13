using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddGroupTopicsAndBotReading : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "BotTalkBotsReadAll",
                table: "Groups",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<bool>(
                name: "BotTalkReplyWithoutMention",
                table: "Groups",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "TopicUpdatedAt",
                table: "Groups",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "TopicUpdatedBy",
                table: "Groups",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "TopicVersion",
                table: "Groups",
                type: "bigint",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "BotTalkBotsReadAll",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "BotTalkReplyWithoutMention",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "TopicUpdatedAt",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "TopicUpdatedBy",
                table: "Groups");

            migrationBuilder.DropColumn(
                name: "TopicVersion",
                table: "Groups");
        }
    }
}
