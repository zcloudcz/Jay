// ---------------------------------------------------------------------------
// FcmSender.cs - Android push via the FCM HTTP v1 API
// ---------------------------------------------------------------------------
// Uses the FCM HTTP v1 API (https://fcm.googleapis.com/v1/.../messages:send)
// authenticated with OAuth2 access tokens from FcmTokenProvider. The legacy
// server-key API this service originally targeted was shut down by Google in
// June 2024 and must not be used.
//
// The access token comes through IFcmAccessTokenSource so tests can run the
// real request/response handling against a fake HttpMessageHandler without
// minting a Google service account.
// ---------------------------------------------------------------------------

using System.Net;
using System.Text;
using System.Text.Json;

namespace CallType.Api.Services;

/// <summary>What <see cref="FcmSender"/> needs from <see cref="FcmTokenProvider"/>.</summary>
public interface IFcmAccessTokenSource
{
    bool IsConfigured { get; }
    string? ProjectId { get; }
    Task<string> GetAccessTokenAsync(CancellationToken ct = default);
}

/// <summary>
/// Outcome of evaluating an FCM HTTP v1 response. Kept separate from the
/// token/DB plumbing so the response-parsing rules from K04 - a bare 404 does
/// NOT prove the token is dead, only a 404 carrying the FCM "UNREGISTERED"
/// error code does - can be unit tested without a database or real HTTP call.
/// </summary>
internal enum FcmSendOutcome
{
    /// <summary>Message accepted, or a transient/unknown failure; token is untouched.</summary>
    Ok,

    /// <summary>Provider confirmed the token is dead (404 + errorCode "UNREGISTERED").</summary>
    TokenUnregistered,
}

/// <summary>
/// Pure response-evaluation logic for FCM HTTP v1, unit tested directly
/// against canned status codes/bodies instead of a live endpoint.
/// </summary>
internal static class FcmResponseEvaluator
{
    /// <summary>
    /// FCM HTTP v1 error responses look like:
    /// { "error": { "code": 404, "status": "NOT_FOUND",
    ///   "details": [{ "@type": "...FcmError", "errorCode": "UNREGISTERED" }] } }
    /// A 404 without that specific errorCode (e.g. a malformed request, or a
    /// generic "not found") must NOT be treated as proof the token is dead.
    /// </summary>
    public static FcmSendOutcome Evaluate(HttpStatusCode statusCode, string responseBody)
    {
        if (statusCode != HttpStatusCode.NotFound)
            return FcmSendOutcome.Ok;

        try
        {
            using var doc = JsonDocument.Parse(responseBody);
            if (doc.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("details", out var details) &&
                details.ValueKind == JsonValueKind.Array)
            {
                foreach (var detail in details.EnumerateArray())
                {
                    if (detail.TryGetProperty("errorCode", out var code) &&
                        code.GetString() == "UNREGISTERED")
                    {
                        return FcmSendOutcome.TokenUnregistered;
                    }
                }
            }
        }
        catch (JsonException)
        {
            // Unparseable body: treat like any other non-UNREGISTERED failure.
        }

        return FcmSendOutcome.Ok;
    }
}

public sealed class FcmSender : IPushSender
{
    public const string HttpClientName = "fcm";

    private readonly IHttpClientFactory _httpFactory;
    private readonly IFcmAccessTokenSource _tokens;
    private readonly ILogger<FcmSender> _logger;

    public FcmSender(IHttpClientFactory httpFactory, IFcmAccessTokenSource tokens, ILogger<FcmSender> logger)
    {
        _httpFactory = httpFactory;
        _tokens = tokens;
        _logger = logger;
        // Logged once here instead of on every message: an unconfigured
        // provider is a deployment state, not an event.
        if (!tokens.IsConfigured)
            logger.LogInformation("FCM push disabled (Push:FcmServiceAccountJson not set)");
    }

    public string Platform => "fcm";

    public bool IsConfigured => _tokens.IsConfigured;

    public async Task<PushSendResult> SendAsync(string token, PushNotification notification, string? locale,
        CancellationToken ct)
    {
        if (!_tokens.IsConfigured) return PushSendResult.Disabled;
        try
        {
            var accessToken = await _tokens.GetAccessTokenAsync(ct);
            var client = _httpFactory.CreateClient(HttpClientName);
            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"https://fcm.googleapis.com/v1/projects/{_tokens.ProjectId}/messages:send");
            request.Headers.Authorization = new("Bearer", accessToken);
            request.Content = new StringContent(PushPayloads.Serialize(PushPayloads.Fcm(token, notification, locale)),
                Encoding.UTF8, "application/json");

            using var response = await client.SendAsync(request, ct);
            if (response.IsSuccessStatusCode) return PushSendResult.Sent;

            // Never log the raw provider body: FCM error messages have echoed
            // back request details in the past, and we must not risk leaking
            // the token or payload into logs (K04).
            var body = await response.Content.ReadAsStringAsync(ct);
            if (FcmResponseEvaluator.Evaluate(response.StatusCode, body) == FcmSendOutcome.TokenUnregistered)
                return PushSendResult.TokenInvalid;
            _logger.LogWarning("FCM push failed with status {StatusCode}", (int)response.StatusCode);
            return PushSendResult.Failed;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            // Push is best-effort: the message is already queued and arrives
            // on the next connect.
            _logger.LogWarning(ex, "FCM push failed with exception");
            return PushSendResult.Failed;
        }
    }
}
