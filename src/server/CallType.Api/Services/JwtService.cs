// ---------------------------------------------------------------------------
// JwtService.cs — JWT token generation and validation for device authentication
// ---------------------------------------------------------------------------
// Devices authenticate by exchanging their device secret (issued at registration)
// for a short-lived JWT. The JWT contains the deviceId as the "sub" claim and
// the userHandle as a custom claim — enough for the server to identify the caller
// without a database lookup on every request.
//
// The signing key is a symmetric HMAC-SHA256 key read from configuration.
// In production this MUST be a high-entropy secret (>= 32 bytes) stored in
// a secret manager — the appsettings.json value is a development placeholder.
// ---------------------------------------------------------------------------

using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.IdentityModel.Tokens;

namespace CallType.Api.Services;

public class JwtService
{
    private readonly SymmetricSecurityKey _signingKey;
    private readonly string _issuer;

    // Token lifetime: 24 hours. Long enough to avoid frequent re-auth for
    // always-on messenger clients, short enough to limit exposure if a token
    // leaks. Clients should proactively refresh before expiry.
    private static readonly TimeSpan TokenLifetime = TimeSpan.FromHours(24);

    // Grace period for refresh: accept expired tokens up to 7 days old for
    // renewal. This lets clients that were offline for a few days refresh
    // without requiring a full re-authentication with the device secret.
    private static readonly TimeSpan RefreshGracePeriod = TimeSpan.FromDays(7);

    public JwtService(IConfiguration configuration)
    {
        var secret = configuration["Jwt:Secret"]
            ?? throw new InvalidOperationException(
                "Jwt:Secret is not configured. JWT authentication requires a signing key.");

        _signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(secret));

        _issuer = configuration["Jwt:Issuer"] ?? "CallType.Api";
    }

    /// <summary>
    /// Creates a signed JWT containing the device identity claims.
    /// </summary>
    /// <returns>The encoded JWT string and its absolute expiration time.</returns>
    public (string Token, DateTimeOffset ExpiresAt) GenerateToken(Guid deviceId, string userHandle)
    {
        var now = DateTimeOffset.UtcNow;
        var expiresAt = now.Add(TokenLifetime);

        var claims = new[]
        {
            // "sub" (subject) is the standard claim for the principal identity.
            // We use deviceId because this is a device-based auth model, not user-based.
            new Claim(JwtRegisteredClaimNames.Sub, deviceId.ToString()),

            // Custom claim for the human-readable handle. Not used for auth decisions,
            // but convenient for logging and debugging without a DB lookup.
            new Claim("handle", userHandle),

            // "iat" (issued at) — standard claim, useful for auditing and debugging
            // token lifetimes. Value is Unix timestamp per RFC 7519.
            new Claim(JwtRegisteredClaimNames.Iat, now.ToUnixTimeSeconds().ToString(),
                ClaimValueTypes.Integer64),

            // "jti" (JWT ID) — unique token identifier to prevent replay attacks
            // if we ever add a token blacklist. Cheap to include now.
            new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())
        };

        var credentials = new SigningCredentials(_signingKey, SecurityAlgorithms.HmacSha256);

        var token = new JwtSecurityToken(
            issuer: _issuer,
            audience: null, // No audience validation — single-API system.
            claims: claims,
            notBefore: now.UtcDateTime,
            expires: expiresAt.UtcDateTime,
            signingCredentials: credentials);

        return (new JwtSecurityTokenHandler().WriteToken(token), expiresAt);
    }

    /// <summary>
    /// Creates a short-lived "step-up" JWT proving a passed TOTP/backup-code
    /// check (N03a). It carries the same device identity as a normal token
    /// plus amr=totp, mfa_at (unix seconds) and mfa_acc (the account the
    /// check was against) — MfaAuthHelper.RequireStepUp reads these three
    /// claims without a DB round trip. Its own `exp` is the step-up lifetime
    /// (short, not the normal 24h), so an expired step-up token is already
    /// rejected by JWT bearer validation before a handler ever sees it.
    ///
    /// IMPORTANT: GenerateToken/RefreshToken above must never copy these
    /// claims forward — they build their claim list from scratch, so a
    /// refreshed token is always a plain (non-step-up) token even if the
    /// token being refreshed was itself a step-up token.
    /// </summary>
    public (string Token, DateTimeOffset ExpiresAt) GenerateStepUpToken(
        Guid deviceId, string userHandle, Guid accountId, TimeSpan lifetime, DateTimeOffset mfaAt)
    {
        var now = DateTimeOffset.UtcNow;
        var expiresAt = now.Add(lifetime);

        var claims = new[]
        {
            new Claim(JwtRegisteredClaimNames.Sub, deviceId.ToString()),
            new Claim("handle", userHandle),
            new Claim(JwtRegisteredClaimNames.Iat, now.ToUnixTimeSeconds().ToString(), ClaimValueTypes.Integer64),
            new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString()),
            new Claim("amr", "totp"),
            new Claim("mfa_at", mfaAt.ToUnixTimeSeconds().ToString(), ClaimValueTypes.Integer64),
            new Claim("mfa_acc", accountId.ToString())
        };

        var credentials = new SigningCredentials(_signingKey, SecurityAlgorithms.HmacSha256);

        var token = new JwtSecurityToken(
            issuer: _issuer,
            audience: null,
            claims: claims,
            notBefore: now.UtcDateTime,
            expires: expiresAt.UtcDateTime,
            signingCredentials: credentials);

        return (new JwtSecurityTokenHandler().WriteToken(token), expiresAt);
    }

    /// <summary>
    /// Validates a token for the refresh flow. Accepts tokens that have expired
    /// within the grace period — the caller can exchange an expired-but-recent
    /// token for a fresh one without re-authenticating with the device secret.
    /// </summary>
    /// <returns>The ClaimsPrincipal if valid (including recently expired); null otherwise.</returns>
    public ClaimsPrincipal? ValidateTokenForRefresh(string token)
    {
        var handler = new JwtSecurityTokenHandler();

        var parameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = _issuer,
            ValidateAudience = false,
            IssuerSigningKey = _signingKey,
            // Allow expired tokens within the grace period for refresh.
            ValidateLifetime = true,
            LifetimeValidator = (notBefore, expires, _, _) =>
            {
                if (expires is null) return false;
                // Accept if the token expired less than RefreshGracePeriod ago.
                return expires.Value.Add(RefreshGracePeriod) > DateTime.UtcNow;
            },
            ClockSkew = TimeSpan.Zero
        };

        try
        {
            return handler.ValidateToken(token, parameters, out _);
        }
        catch (SecurityTokenException)
        {
            return null;
        }
    }
}
