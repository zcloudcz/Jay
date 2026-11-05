using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddChannelModeration : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "SuspendedUntil",
                table: "Channels",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Category",
                table: "ChannelReports",
                type: "character varying(10)",
                maxLength: 10,
                nullable: false,
                defaultValue: "terms");

            migrationBuilder.AddColumn<string>(
                name: "ContactEmail",
                table: "ChannelReports",
                type: "character varying(254)",
                maxLength: 254,
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "DecisionId",
                table: "ChannelReports",
                type: "bigint",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "GoodFaith",
                table: "ChannelReports",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ResolvedAt",
                table: "ChannelReports",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Status",
                table: "ChannelReports",
                type: "character varying(10)",
                maxLength: 10,
                nullable: false,
                defaultValue: "open");

            migrationBuilder.CreateTable(
                name: "ModerationDecisions",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    ChannelId = table.Column<Guid>(type: "uuid", nullable: false),
                    PostId = table.Column<Guid>(type: "uuid", nullable: true),
                    Action = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    Ground = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: true),
                    Rule = table.Column<string>(type: "character varying(3)", maxLength: 3, nullable: true),
                    LegalGround = table.Column<string>(type: "character varying(300)", maxLength: 300, nullable: true),
                    Explanation = table.Column<string>(type: "character varying(2000)", maxLength: 2000, nullable: false),
                    SuspendedUntil = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    OperatorAccountId = table.Column<Guid>(type: "uuid", nullable: false),
                    ReportCount = table.Column<int>(type: "integer", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ModerationDecisions", x => x.Id);
                    table.ForeignKey(
                        name: "FK_ModerationDecisions_Channels_ChannelId",
                        column: x => x.ChannelId,
                        principalTable: "Channels",
                        principalColumn: "ChannelId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_ChannelReports_DecisionId",
                table: "ChannelReports",
                column: "DecisionId");

            migrationBuilder.CreateIndex(
                name: "IX_ChannelReports_Status_CreatedAt",
                table: "ChannelReports",
                columns: new[] { "Status", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_ModerationDecisions_ChannelId_CreatedAt",
                table: "ModerationDecisions",
                columns: new[] { "ChannelId", "CreatedAt" });

            migrationBuilder.AddForeignKey(
                name: "FK_ChannelReports_ModerationDecisions_DecisionId",
                table: "ChannelReports",
                column: "DecisionId",
                principalTable: "ModerationDecisions",
                principalColumn: "Id",
                onDelete: ReferentialAction.SetNull);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_ChannelReports_ModerationDecisions_DecisionId",
                table: "ChannelReports");

            migrationBuilder.DropTable(
                name: "ModerationDecisions");

            migrationBuilder.DropIndex(
                name: "IX_ChannelReports_DecisionId",
                table: "ChannelReports");

            migrationBuilder.DropIndex(
                name: "IX_ChannelReports_Status_CreatedAt",
                table: "ChannelReports");

            migrationBuilder.DropColumn(
                name: "SuspendedUntil",
                table: "Channels");

            migrationBuilder.DropColumn(
                name: "Category",
                table: "ChannelReports");

            migrationBuilder.DropColumn(
                name: "ContactEmail",
                table: "ChannelReports");

            migrationBuilder.DropColumn(
                name: "DecisionId",
                table: "ChannelReports");

            migrationBuilder.DropColumn(
                name: "GoodFaith",
                table: "ChannelReports");

            migrationBuilder.DropColumn(
                name: "ResolvedAt",
                table: "ChannelReports");

            migrationBuilder.DropColumn(
                name: "Status",
                table: "ChannelReports");
        }
    }
}
