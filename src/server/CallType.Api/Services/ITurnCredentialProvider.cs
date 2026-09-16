// ---------------------------------------------------------------------------
// ITurnCredentialProvider.cs — abstraction over TURN credential issuers
// ---------------------------------------------------------------------------
// Two providers exist: the self-hosted shared-secret HMAC scheme (coturn /
// DeskShare.Turn) and Cloudflare TURN (credentials minted by Cloudflare's
// API). The endpoint only cares about the resulting ICE credential set, so it
// depends on this interface and Program.cs picks the implementation from
// Turn:Provider. Clients see an identical response either way.
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

public interface ITurnCredentialProvider
{
    /// <summary>Issues time-limited ICE credentials for the given device.</summary>
    /// <exception cref="TurnUnavailableException">Provider could not issue credentials (e.g. upstream API down).</exception>
    Task<TurnIceCredentials> IssueAsync(Guid deviceId, CancellationToken cancellationToken);
}

/// <summary>Credential set handed to the client's ICE agent. Shape is shared by all providers.</summary>
public record TurnIceCredentials(
    string Username,
    string Credential,
    int TtlSeconds,
    string[] Urls,
    string[] StunUrls);

/// <summary>
/// Raised when a provider cannot issue credentials right now. Never carries the
/// upstream response body — it may echo request details or secrets.
/// </summary>
public class TurnUnavailableException(string message) : Exception(message);
