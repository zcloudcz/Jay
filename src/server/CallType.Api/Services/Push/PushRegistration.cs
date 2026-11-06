// ---------------------------------------------------------------------------
// PushRegistration.cs - Validation of PUT /devices/{id}/push-token bodies
// ---------------------------------------------------------------------------
// Pure function so every platform rule of the contract (section 1.1) is
// unit tested without HTTP. Returns the token in the form it is STORED in:
// APNs hex lowercased, Web Push subscription re-serialized canonically.
// ---------------------------------------------------------------------------

using System.Text.RegularExpressions;

namespace CallType.Api.Services;

public static partial class PushRegistration
{
    public const int MaxTokenLength = 2048;
    public const int MaxLocaleLength = 16;

    public static readonly string[] Platforms = ["fcm", "apns", "webpush"];

    /// <summary>Error codes of the contract, returned as the "error" extension of a 400.</summary>
    public const string InvalidPlatform = "invalid_platform";
    public const string InvalidToken = "invalid_token";
    public const string InvalidLocale = "invalid_locale";

    public static (string? Token, string? Error) ValidateToken(string? platform, string? token)
    {
        if (platform is null || !Platforms.Contains(platform)) return (null, InvalidPlatform);
        if (string.IsNullOrWhiteSpace(token) || token.Length > MaxTokenLength) return (null, InvalidToken);
        switch (platform)
        {
            case "apns":
                // Apple device tokens are 32 bytes today but Apple documents
                // them as variable length, hence 64..200 hex chars instead of 64.
                var hex = token.Trim();
                return ApnsToken().IsMatch(hex) ? (hex.ToLowerInvariant(), null) : (null, InvalidToken);
            case "webpush":
                var subscription = WebPushSubscription.TryParse(token);
                return subscription is null ? (null, InvalidToken) : (subscription.ToJson(), null);
            default:
                // FCM tokens are opaque; only Google can tell whether one is real.
                return (token.Trim(), null);
        }
    }

    /// <summary>Null/blank = no locale (English texts). Loose BCP-47 shape, "_" tolerated.</summary>
    public static (string? Locale, string? Error) ValidateLocale(string? locale)
    {
        if (string.IsNullOrWhiteSpace(locale)) return (null, null);
        var trimmed = locale.Trim();
        return trimmed.Length <= MaxLocaleLength && LocaleShape().IsMatch(trimmed)
            ? (trimmed, null)
            : (null, InvalidLocale);
    }

    [GeneratedRegex("^[0-9a-fA-F]{64,200}$")]
    private static partial Regex ApnsToken();

    [GeneratedRegex("^[A-Za-z]{2,8}([-_][A-Za-z0-9]{1,8})*$")]
    private static partial Regex LocaleShape();
}
