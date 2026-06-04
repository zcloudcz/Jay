// ---------------------------------------------------------------------------
// TurnCredentialService.cs — Time-limited TURN credential generation
// ---------------------------------------------------------------------------
// Generates HMAC-SHA1 credentials compatible with the DeskShare.Turn server
// from RemoteDesktopNet. The shared-secret scheme (RFC 5766 S4, also used by
// coturn and the "long-term credential with shared secret" pattern) works as:
//
//   username = "{unix_expiry}:{deviceId}"
//   credential = Base64(HMAC-SHA1(sharedSecret, username))
//
// The TURN server independently computes the same HMAC to verify the client.
// The expiry timestamp is embedded in the username so the TURN server can
// reject expired credentials without a database lookup.
//
// This service is registered as a singleton because it is stateless — it
// only reads configuration and computes HMACs. No DbContext dependency.
// ---------------------------------------------------------------------------

using System.Security.Cryptography;
using System.Text;

namespace CallType.Api.Services;

public class TurnCredentialService
{
    private readonly byte[] _sharedSecret;
    private readonly int _ttlSeconds;

    public TurnCredentialService(IConfiguration configuration)
    {
        // The shared secret must match the one configured on the DeskShare.Turn
        // server. If missing, TURN credentials cannot be issued — fail fast.
        var secret = configuration["Turn:SharedSecret"]
            ?? throw new InvalidOperationException(
                "Turn:SharedSecret is not configured. TURN credential generation requires a shared secret.");

        _sharedSecret = Encoding.UTF8.GetBytes(secret);

        // Default 24h TTL — long enough for multi-hour calls, short enough to
        // limit abuse if a credential leaks.
        _ttlSeconds = int.TryParse(configuration["Turn:TtlSeconds"], out var ttl) ? ttl : 86400;
    }

    /// <summary>
    /// Generates a time-limited TURN credential for the given device.
    /// </summary>
    /// <param name="deviceId">The device requesting TURN access.</param>
    /// <param name="utcNow">
    /// Current UTC time. Parameterized for testability — callers pass
    /// DateTimeOffset.UtcNow in production, but tests can pin the time.
    /// </param>
    public TurnCredentials Generate(Guid deviceId, DateTimeOffset utcNow)
    {
        var expiryUnix = utcNow.AddSeconds(_ttlSeconds).ToUnixTimeSeconds();

        // Username format matches the DeskShare.Turn expectation:
        // expiry_unix:deviceId — the TURN server splits on ':' to extract
        // the timestamp for expiry checking.
        var username = $"{expiryUnix}:{deviceId}";

        // HMAC-SHA1 is required by the TURN shared-secret spec (RFC 5389 / coturn).
        // SHA1 is fine here — we need MAC security, not collision resistance.
        using var hmac = new HMACSHA1(_sharedSecret);
        var usernameBytes = Encoding.UTF8.GetBytes(username);
        var hash = hmac.ComputeHash(usernameBytes);
        var credential = Convert.ToBase64String(hash);

        return new TurnCredentials(username, credential, _ttlSeconds);
    }
}

/// <summary>
/// TURN credential response returned to the client. The client passes these
/// to the WebRTC ICE agent for NAT traversal.
/// </summary>
public record TurnCredentials(string Username, string Credential, int TtlSeconds);
