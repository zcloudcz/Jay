using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Audit.Migrations
{
    /// <inheritdoc />
    public partial class OrgRequireBusinessConversations : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "RequireBusinessConversations",
                table: "Organizations",
                type: "boolean",
                nullable: false,
                defaultValue: false);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "RequireBusinessConversations",
                table: "Organizations");
        }
    }
}
