// ---------------------------------------------------------------------------
// MfaAuthHelper.cs — the ONLY integration surface N03b needs (N03a)
// ---------------------------------------------------------------------------
// A pure claims check, no DB round trip: the step-up token was already
// minted by JwtService.GenerateStepUpToken after a DB-backed TOTP/backup-code
// verification, so trusting its claims here is trusting our own signature.
//
// N03b wires RequireStepUp into every OrgAdmin+ endpoint in
// OrganizationEndpoints.cs and EmergencyEndpoints.cs — see the "N03 — MFA"
// section of docs/superpowers/plans/2026-09-18-business-mode-contracts.md
// for the exact list. This package does NOT call it from anywhere.
// ---------------------------------------------------------------------------

using System.Security.Claims;

namespace CallType.Api.Endpoints;

public static class MfaAuthHelper
{
    /// <summary>
    /// Matches JwtService's step-up token lifetime default (Mfa:StepUpMinutes,
    /// default 15) — kept here too as a second, defense-in-depth check on top
    /// of the token's own `exp`, in case a token is ever minted with a longer
    /// lifetime than intended.
    /// </summary>
    public const int DefaultWindowMinutes = 15;

    /// <summary>
    /// Null when the caller's token carries a valid, recent step-up proof for
    /// this exact account; otherwise a ready-to-return 403 mfa_required.
    /// </summary>
    public static IResult? RequireStepUp(ClaimsPrincipal user, Guid accountId, TimeProvider clock)
    {
        if (user.FindFirst("amr")?.Value == "totp"
            && Guid.TryParse(user.FindFirst("mfa_acc")?.Value, out var mfaAccountId)
            && mfaAccountId == accountId
            && long.TryParse(user.FindFirst("mfa_at")?.Value, out var mfaAtUnix))
        {
            var mfaAt = DateTimeOffset.FromUnixTimeSeconds(mfaAtUnix);
            if (clock.GetUtcNow() - mfaAt <= TimeSpan.FromMinutes(DefaultWindowMinutes))
                return null;
        }

        return Results.Json(
            new { error = "This action requires a recent MFA verification.", code = "mfa_required" },
            statusCode: StatusCodes.Status403Forbidden);
    }
}
