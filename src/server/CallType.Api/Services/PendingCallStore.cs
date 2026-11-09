// ---------------------------------------------------------------------------
// PendingCallStore.cs - Calls ringing on a device that is not connected yet
// ---------------------------------------------------------------------------
// Spec docs/superpowers/specs/2026-11-06-call-ringing.md (R1, R6, 1.2).
// When an offer reaches an offline callee that can ring (VoIP / Android
// ringCalls), the offer and the caller's trickled ICE candidates wait here
// until the callee's app is woken by the ring push and connects. A caller
// hangup (or the 45 s ring timeout) turns the call into a short-lived
// TOMBSTONE, so the callee's app, which may be showing CallKit or a
// full-screen notification by then, learns the call is gone.
//
// In memory on purpose: a pending call lives 45 s, and the API runs as ONE
// App Service instance (AGENTS.md design decision 6). A restart loses at most
// the calls ringing at that moment; the caller then times out as before.
// Move this to a shared store together with the SignalR backplane if the API
// is ever scaled out.
//
// Delivery on connect does not forget the call completely: the app must be
// connected to invoke DeclinePendingCall, and connecting already delivered
// the offer. A "delivered" marker (no signals) therefore stays until the
// ring timeout so a lock-screen decline still reaches the caller.
//
// Not IMemoryCache: the hub must enumerate every pending call and tombstone
// of ONE device on connect, which IMemoryCache cannot do, and expiry must be
// testable with a fake clock. Expiry is therefore checked lazily on every
// access (an expired pending call becomes a tombstone at its expiry time),
// plus a sweep of all devices at most once a minute so devices that never
// come back cannot keep entries alive.
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

/// <summary>One relayed signal, kept in arrival order.</summary>
public sealed record PendingCallSignal(string SignalType, string Payload);

/// <summary>A call waiting for its callee to connect.</summary>
public sealed class PendingCall
{
    public required string CallId { get; init; }
    public required Guid CallerDeviceId { get; init; }
    public required Guid TargetDeviceId { get; init; }
    public Guid? BusinessGroupId { get; init; }

    /// <summary>The push route (business group or the caller's identity), reused by call_cancelled.</summary>
    public Guid ConversationId { get; init; }

    /// <summary>Stamped by <see cref="PendingCallStore.TryAdd"/> from the store's clock.</summary>
    public DateTimeOffset CreatedAt { get; internal set; }
    public List<PendingCallSignal> Signals { get; } = [];
}

/// <summary>
/// A call that rang and was cancelled (caller hangup or ring timeout) before
/// the callee connected. <see cref="CancelPushed"/> remembers whether the
/// Android call_cancelled push already went out for it.
/// </summary>
public sealed class CallTombstone
{
    public required string CallId { get; init; }
    public required Guid CallerDeviceId { get; init; }
    public Guid? BusinessGroupId { get; init; }
    public Guid ConversationId { get; init; }
    public required DateTimeOffset ExpiresAt { get; init; }
    public bool CancelPushed { get; set; }
}

/// <summary>What a connecting callee receives, already removed from the store.</summary>
public sealed record PendingCallDelivery(IReadOnlyList<PendingCall> Calls, IReadOnlyList<CallTombstone> Tombstones);

public sealed class PendingCallStore(TimeProvider clock)
{
    /// <summary>The caller app's ring timeout (R1): a pending call is useless after it.</summary>
    public static readonly TimeSpan RingTimeout = TimeSpan.FromSeconds(45);

    /// <summary>How long a cancelled call is remembered for the callee (R6).</summary>
    public static readonly TimeSpan TombstoneLifetime = TimeSpan.FromMinutes(2);

    /// <summary>Offer + ICE candidates per call; a real call needs a dozen or two.</summary>
    public const int MaxSignalsPerCall = 64;

    /// <summary>
    /// Bounds memory per callee. Real life is one or two callers at a time;
    /// above the cap an offer falls back to the legacy "unavailable" path.
    /// </summary>
    public const int MaxPendingPerTarget = 8;

    /// <summary>Oldest tombstones are dropped beyond this (offer/hangup loops).</summary>
    public const int MaxTombstonesPerTarget = 32;

    private static readonly TimeSpan SweepInterval = TimeSpan.FromMinutes(1);

    private sealed class TargetState
    {
        public readonly List<PendingCall> Calls = [];
        public readonly List<CallTombstone> Tombstones = [];
        public readonly List<PendingCall> Delivered = [];
        public bool IsEmpty => Calls.Count == 0 && Tombstones.Count == 0 && Delivered.Count == 0;
    }

    // One lock for the whole store: every operation is a few list operations
    // on tiny lists, far cheaper than the hub round trip around it.
    private readonly Lock _lock = new();
    private readonly Dictionary<Guid, TargetState> _targets = new();
    private DateTimeOffset _lastSweep = DateTimeOffset.MinValue;

    /// <summary>
    /// Stores a new pending call with its offer. False when the same
    /// (target, callId) is already pending or the target is at its cap.
    /// </summary>
    public bool TryAdd(PendingCall call)
    {
        lock (_lock)
        {
            var now = clock.GetUtcNow();
            SweepIfDue(now);
            var state = State(call.TargetDeviceId, now, create: true)!;
            if (state.Calls.Count >= MaxPendingPerTarget || state.Calls.Any(c => c.CallId == call.CallId))
            {
                if (state.IsEmpty) _targets.Remove(call.TargetDeviceId);
                return false;
            }
            call.CreatedAt = now;
            state.Calls.Add(call);
            return true;
        }
    }

    /// <summary>True when the caller has a live pending call with this id to the target.</summary>
    public bool HasPending(Guid target, string callId, Guid caller)
    {
        lock (_lock)
            return Find(State(target, clock.GetUtcNow(), create: false), callId, caller) is not null;
    }

    /// <summary>
    /// Appends a follow-up signal (ICE) of the SAME caller to its pending call.
    /// True = handled (stored, or dropped beyond the cap); false = no such
    /// pending call, the caller handles the signal as before.
    /// </summary>
    public bool TryAppend(Guid target, string callId, Guid caller, PendingCallSignal signal)
    {
        lock (_lock)
        {
            var call = Find(State(target, clock.GetUtcNow(), create: false), callId, caller);
            if (call is null) return false;
            if (call.Signals.Count < MaxSignalsPerCall) call.Signals.Add(signal);
            return true;
        }
    }

    /// <summary>
    /// Caller hangup. A live pending call becomes a tombstone. Returns the
    /// tombstone when the Android call_cancelled push is still due for it
    /// (also for a call whose ring already timed out, so the caller app's
    /// own timeout hangup still dismisses the notification), else null.
    /// </summary>
    public CallTombstone? Cancel(Guid target, string callId, Guid caller)
    {
        lock (_lock)
        {
            var now = clock.GetUtcNow();
            var state = State(target, now, create: false);
            if (state is null) return null;
            CallTombstone? tombstone;
            var call = Find(state, callId, caller);
            if (call is not null)
            {
                state.Calls.Remove(call);
                tombstone = AddTombstone(state, call, now);
            }
            else
            {
                tombstone = state.Tombstones.FirstOrDefault(t => t.CallId == callId && t.CallerDeviceId == caller);
                if (tombstone is null || tombstone.CancelPushed) return null;
            }
            tombstone.CancelPushed = true;
            return tombstone;
        }
    }

    /// <summary>
    /// Callee declined on the lock screen (R7): removes the call addressed to
    /// <paramref name="target"/>, still pending or already delivered on
    /// connect but within its ring time, without a tombstone (the callee
    /// already knows). Null when there is none.
    /// </summary>
    public PendingCall? Decline(Guid target, string callId)
    {
        lock (_lock)
        {
            var now = clock.GetUtcNow();
            var state = State(target, now, create: false);
            if (state is null) return null;
            var call = state.Calls.FirstOrDefault(c => c.CallId == callId);
            if (call is not null) state.Calls.Remove(call);
            else if ((call = state.Delivered.FirstOrDefault(c => c.CallId == callId)) is not null)
                state.Delivered.Remove(call);
            if (state.IsEmpty) _targets.Remove(target);
            return call;
        }
    }

    /// <summary>
    /// Removes and returns everything waiting for this device (delivered
    /// once). Delivered calls are remembered, without their signals, only
    /// for <see cref="Decline"/>.
    /// </summary>
    public PendingCallDelivery TakeAll(Guid target)
    {
        lock (_lock)
        {
            var state = State(target, clock.GetUtcNow(), create: false);
            if (state is null) return new([], []);
            var delivery = new PendingCallDelivery(state.Calls.ToList(), state.Tombstones.ToList());
            foreach (var call in state.Calls)
                state.Delivered.Add(new PendingCall
                {
                    CallId = call.CallId,
                    CallerDeviceId = call.CallerDeviceId,
                    TargetDeviceId = call.TargetDeviceId,
                    BusinessGroupId = call.BusinessGroupId,
                    CreatedAt = call.CreatedAt,
                });
            state.Calls.Clear();
            state.Tombstones.Clear();
            if (state.IsEmpty) _targets.Remove(target);
            return delivery;
        }
    }

    // --- internals (all called under _lock) ---------------------------------

    private static PendingCall? Find(TargetState? state, string callId, Guid caller) =>
        state?.Calls.FirstOrDefault(c => c.CallId == callId && c.CallerDeviceId == caller);

    /// <summary>The target's state with expired entries already applied.</summary>
    private TargetState? State(Guid target, DateTimeOffset now, bool create)
    {
        if (_targets.TryGetValue(target, out var state))
        {
            Expire(state, now);
            if (!state.IsEmpty || create) return state;
            _targets.Remove(target);
            return null;
        }
        if (!create) return null;
        state = new TargetState();
        _targets[target] = state;
        return state;
    }

    private static void Expire(TargetState state, DateTimeOffset now)
    {
        // R6: a ring that timed out is a missed call, same as a hangup.
        // The tombstone counts from the expiry, not from now, so a sweep
        // that runs late does not extend its life.
        foreach (var call in state.Calls.Where(c => now - c.CreatedAt >= RingTimeout).ToList())
        {
            state.Calls.Remove(call);
            AddTombstone(state, call, call.CreatedAt + RingTimeout);
        }
        state.Tombstones.RemoveAll(t => t.ExpiresAt <= now);
        state.Delivered.RemoveAll(c => now - c.CreatedAt >= RingTimeout);
    }

    private static CallTombstone AddTombstone(TargetState state, PendingCall call, DateTimeOffset cancelledAt)
    {
        var tombstone = new CallTombstone
        {
            CallId = call.CallId,
            CallerDeviceId = call.CallerDeviceId,
            BusinessGroupId = call.BusinessGroupId,
            ConversationId = call.ConversationId,
            ExpiresAt = cancelledAt + TombstoneLifetime,
        };
        state.Tombstones.Add(tombstone);
        if (state.Tombstones.Count > MaxTombstonesPerTarget) state.Tombstones.RemoveAt(0);
        return tombstone;
    }

    private void SweepIfDue(DateTimeOffset now)
    {
        if (now - _lastSweep < SweepInterval) return;
        _lastSweep = now;
        foreach (var (target, state) in _targets.ToList())
        {
            Expire(state, now);
            if (state.IsEmpty) _targets.Remove(target);
        }
    }
}
