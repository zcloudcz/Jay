// ---------------------------------------------------------------------------
// PendingCallOptions.cs — limits of the in-memory pending call offers (KC3)
// ---------------------------------------------------------------------------
// Bound from the "Calls" configuration section (Calls__* env vars). Values and
// meaning: docs/superpowers/plans/2026-09-29-gap-calls.md KC3 / C02. Created
// by X0 so stream C and stream N can build in parallel; PendingCallStore
// (stream C, C02) is the only consumer.
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

public class PendingCallOptions
{
    public const string SectionName = "Calls";

    /// <summary>How long an offer to an offline callee stays claimable, from creation.</summary>
    public int PendingTtlSeconds { get; set; } = 45;

    /// <summary>
    /// A live-delivered offer without a "ringing" reply after this long is
    /// treated as a dead socket and falls back to a push (sequence E).
    /// </summary>
    public int RingAckSeconds { get; set; } = 5;

    /// <summary>
    /// How long an ended offer (cancelled/declined/answered/expired) is kept so
    /// ClaimPendingCall can still answer "cancelled" instead of "unknown".
    /// </summary>
    public int TombstoneSeconds { get; set; } = 120;

    /// <summary>Live offers per callee; one more gets "unavailable" (memory bound).</summary>
    public int MaxPendingPerCallee { get; set; } = 4;

    /// <summary>ICE candidates kept per pending offer for re-delivery.</summary>
    public int MaxIcePerCall { get; set; } = 64;

    /// <summary>Call pushes per caller per sliding minute — protection against "ring bombing".</summary>
    public int MaxCallPushesPerCallerPerMinute { get; set; } = 6;
}
