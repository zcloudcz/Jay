using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class EmergencyGroupFlag : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "IsEmergencyChannel",
                table: "Groups",
                type: "boolean",
                nullable: false,
                defaultValue: false);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "IsEmergencyChannel",
                table: "Groups");
        }
    }
}
