using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CallType.Api.Migrations
{
    /// <inheritdoc />
    public partial class SignedIdentityBundles : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<byte[]>(
                name: "Signature",
                table: "Devices",
                type: "bytea",
                nullable: true);

            migrationBuilder.AddColumn<byte[]>(
                name: "SigningKey",
                table: "Devices",
                type: "bytea",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Signature",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "SigningKey",
                table: "Devices");
        }
    }
}
