// ---------------------------------------------------------------------------
// ICallPushSender.cs — wake a callee's device for an incoming call (frozen in X0)
// ---------------------------------------------------------------------------
// Contract KC4 (docs/superpowers/plans/2026-09-29-gap-calls.md §3) as amended
// by gap-contracts K5:
//   - CallPush carries CallerId, but the caller identity may leave this server
//     ONLY encrypted inside the hint "h" with the callee's Device.PushKey
//     (notifications plan R2) — never readable by Apple or Google.
//   - SendCallCancelPushAsync carries a CallCancelReason (enum from stream N).
// Stream C (hub, PendingCallSweeper) calls it; stream N implements it. The X0
// implementation in PushNotificationService answers NotConfigured, which the
// hub treats exactly like today's "callee offline" path (signal "unavailable").
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

/// <summary>Outcome of <see cref="ICallPushSender.SendCallPushAsync"/>.</summary>
public enum CallPushResult { NoToken, NotConfigured, Sent, Failed }

/// <summary>
/// Why a ringing call is being cancelled. Wire values (push payload):
/// "caller_hangup" | "timeout" | "answered_elsewhere" | "rejected".
/// </summary>
public enum CallCancelReason { CallerHangup, Timeout, AnsweredElsewhere, Rejected }

/// <param name="CallId">The call's UUID (from the call envelope).</param>
/// <param name="CallerId">
/// Calling device. Only ever sent encrypted (hint "h" under the callee's
/// PushKey); without a PushKey it is simply left out of the push.
/// </param>
/// <param name="Video">From the offer envelope; drives the native call UI type.</param>
/// <param name="DeclineToken">32 random bytes, base64url — lets the callee decline without a JWT.</param>
/// <param name="ExpiresAt">When the pending offer expires; becomes the push TTL/expiration.</param>
public sealed record CallPush(Guid CallId, Guid CallerId, bool Video, string DeclineToken, DateTimeOffset ExpiresAt);

public interface ICallPushSender
{
    /// <summary>
    /// Wakes the callee's device for an incoming call. Returns Sent only when a
    /// provider accepted a push that can present a ringing UI (APNs VoIP or
    /// FCM high-priority data / webpush). Never throws.
    /// </summary>
    Task<CallPushResult> SendCallPushAsync(Guid calleeDeviceId, CallPush push, CancellationToken ct);

    /// <summary>
    /// Best-effort: stops a ringing native UI after the call ended before the
    /// callee connected (caller hung up, timeout, answered elsewhere, declined).
    /// Never throws.
    /// </summary>
    Task SendCallCancelPushAsync(Guid calleeDeviceId, Guid callId, CallCancelReason reason, CancellationToken ct);
}
