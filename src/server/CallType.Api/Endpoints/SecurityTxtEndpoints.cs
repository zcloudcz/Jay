// ---------------------------------------------------------------------------
// SecurityTxtEndpoints.cs — RFC 9116 security.txt (N04)
// ---------------------------------------------------------------------------
// GET /.well-known/security.txt — anonymous, text/plain.
// The real security contact is not known yet (see docs/security/
// incident-response.md, TODO(owner)), so we refuse to publish a guessed one:
// the contact comes from config key Security:ContactUri, and when it is
// empty the endpoint returns 404 — a missing security.txt is honest, a wrong
// one is not.
// ---------------------------------------------------------------------------

namespace CallType.Api.Endpoints;

public static class SecurityTxtEndpoints
{
    public static void MapSecurityTxtEndpoints(this WebApplication app)
    {
        app.MapGet("/.well-known/security.txt", (IConfiguration configuration) =>
        {
            var contactUri = configuration["Security:ContactUri"];
            if (string.IsNullOrWhiteSpace(contactUri))
                return Results.NotFound();

            // RFC 9116 requires Expires; a year out is the field's usual convention
            // and keeps the file from being trusted indefinitely if abandoned.
            var expires = DateTimeOffset.UtcNow.AddYears(1).ToString("yyyy-MM-ddTHH:mm:ssZ");
            var body = $"""
                Contact: {contactUri}
                Expires: {expires}
                Preferred-Languages: cs, en
                """;
            return Results.Text(body, "text/plain");
        }).AllowAnonymous();
    }
}
