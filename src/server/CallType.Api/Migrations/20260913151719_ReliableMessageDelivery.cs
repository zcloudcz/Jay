using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class ReliableMessageDelivery : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "AcknowledgedAt",
                table: "QueuedMessages",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "GroupId",
                table: "QueuedMessages",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "MessageId",
                table: "QueuedMessages",
                type: "uuid",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));

            migrationBuilder.Sql("UPDATE \"QueuedMessages\" SET \"MessageId\" = gen_random_uuid()");

            migrationBuilder.CreateIndex(
                name: "IX_QueuedMessages_RecipientId_SenderId_MessageId",
                table: "QueuedMessages",
                columns: new[] { "RecipientId", "SenderId", "MessageId" },
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_QueuedMessages_RecipientId_SenderId_MessageId",
                table: "QueuedMessages");

            migrationBuilder.DropColumn(
                name: "AcknowledgedAt",
                table: "QueuedMessages");

            migrationBuilder.DropColumn(
                name: "GroupId",
                table: "QueuedMessages");

            migrationBuilder.DropColumn(
                name: "MessageId",
                table: "QueuedMessages");
        }
    }
}

