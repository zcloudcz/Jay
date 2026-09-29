// ---------------------------------------------------------------------------
// PendingCallStore.cs — in-memory pending call offers (KC3) — X0 STUB
// ---------------------------------------------------------------------------
// Stream C (package C02) fills this in: offers to offline / not-yet-ringing
// callees, their ICE candidates, decline tokens and tombstones, all in process
// memory. Same bound as ChannelPushThrottle: correct only because the API runs
// as exactly ONE instance (CLAUDE.md design decision 6).
//
// X0 only registers the singleton so the hub, PendingCallSweeper and
// CallEndpoints can take it as a dependency while stream C and stream N work
// in parallel.
// ---------------------------------------------------------------------------

using Microsoft.Extensions.Options;

namespace CallType.Api.Services;

public sealed class PendingCallStore(TimeProvider time, IOptions<PendingCallOptions> options)
{
    // Exposed (instead of unread primary-constructor parameters) so the stub
    // compiles without warnings; C02 uses both for TTLs and the push budget.
    internal TimeProvider Time { get; } = time;
    internal PendingCallOptions Options { get; } = options.Value;
}
