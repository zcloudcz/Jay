// ---------------------------------------------------------------------------
// CallEndpoints.cs — REST side of call setup (KC5) — X0 STUB
// ---------------------------------------------------------------------------
// Stream C (package C02) adds POST /calls/{callId:guid}/decline here (callee
// declines from a native call UI, with a JWT or the one-time declineToken from
// the call push). X0 only wires MapCallEndpoints into Program.cs so that wave 1
// changes this file and not the hot Program.cs.
// No 501 placeholder route: no other stream compiles against it, and an
// always-501 route would only mask a missing implementation in a client test.
// ---------------------------------------------------------------------------

namespace CallType.Api.Endpoints;

public static class CallEndpoints
{
    public static WebApplication MapCallEndpoints(this WebApplication app) => app;
}
