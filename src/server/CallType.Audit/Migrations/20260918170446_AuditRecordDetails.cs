using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Audit.Migrations
{
    /// <inheritdoc />
    public partial class AuditRecordDetails : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "DetailsJson",
                table: "AuditRecords",
                type: "text",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "DetailsJson",
                table: "AuditRecords");
        }
    }
}
