// ---------------------------------------------------------------------------
// PendingCallSweeper.cs — ring-ack timeouts and expiry of pending calls — X0 STUB
// ---------------------------------------------------------------------------
// Stream C (package C02) implements it: a 1 s PeriodicTimer that turns live
// offers without a "ringing" reply into pushes (dead socket) and every 10 s
// sweeps expired offers and tombstones out of PendingCallStore. X0 registers
// the hosted service so Program.cs does not need to change again in wave 1.
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

public sealed class PendingCallSweeper : BackgroundService
{
    // Returns immediately: with the stub store there is nothing to sweep, and
    // a completed ExecuteAsync is a normal, silent end for a BackgroundService.
    protected override Task ExecuteAsync(CancellationToken stoppingToken) => Task.CompletedTask;
}
