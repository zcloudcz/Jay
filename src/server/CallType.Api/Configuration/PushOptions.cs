// ---------------------------------------------------------------------------
// PushOptions.cs - Configuration for the APNs and Web Push providers
// ---------------------------------------------------------------------------
// Bound from "Push:Apns" and "Push:WebPush" (env: Push__Apns__KeyId, ...).
// FCM keeps its single existing key Push:FcmServiceAccountJson, read by
// FcmTokenProvider. Every provider is optional: empty keys disable it and the
// API runs unchanged, messages still arrive through store-and-forward.
// Contract: docs/superpowers/specs/2026-11-06-notifications.md section 1.2.
// ---------------------------------------------------------------------------

namespace CallType.Api.Configuration;

public class ApnsOptions
{
    public const string SectionName = "Push:Apns";

    /// <summary>Key ID of the APNs auth key (.p8), 10 characters from the Apple developer portal.</summary>
    public string? KeyId { get; set; }

    /// <summary>Apple developer team (the JWT issuer).</summary>
    public string TeamId { get; set; } = "DZR3FD9ZNT";

    /// <summary>Bundle id of the iOS app; APNs routes on it (apns-topic).</summary>
    public string BundleId { get; set; } = "cz.zcloud.jay";

    /// <summary>PEM text of the .p8 file ("-----BEGIN PRIVATE KEY-----...").</summary>
    public string? PrivateKeyP8 { get; set; }

    /// <summary>
    /// True = api.sandbox.push.apple.com. Default false because TestFlight and
    /// App Store builds both carry production device tokens; only builds run
    /// from Xcode need the sandbox.
    /// </summary>
    public bool UseSandbox { get; set; }

    public bool IsConfigured => !string.IsNullOrWhiteSpace(KeyId) && !string.IsNullOrWhiteSpace(PrivateKeyP8);
}

public class WebPushOptions
{
    public const string SectionName = "Push:WebPush";

    /// <summary>VAPID public key: base64url of the uncompressed P-256 point (65 bytes).</summary>
    public string? PublicKey { get; set; }

    /// <summary>VAPID private key: base64url of the 32-byte P-256 scalar.</summary>
    public string? PrivateKey { get; set; }

    /// <summary>
    /// VAPID "sub" claim. Push services use it to contact the operator when a
    /// sender misbehaves, so it must be a reachable mailto: or https: URL.
    /// </summary>
    public string Subject { get; set; } = "mailto:martin@zcloud.cz";

    public bool IsConfigured => !string.IsNullOrWhiteSpace(PublicKey) && !string.IsNullOrWhiteSpace(PrivateKey);
}
