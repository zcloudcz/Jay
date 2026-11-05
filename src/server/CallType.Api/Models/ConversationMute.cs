// ---------------------------------------------------------------------------
// ConversationMute.cs - A device's mute of one conversation (design D6)
// ---------------------------------------------------------------------------
// Per DEVICE, not per identity: a user may want the phone silent but the
// desktop not. Exactly one of GroupId / PeerPrimaryDeviceId is set:
//   - GroupId: mute of a group conversation.
//   - PeerPrimaryDeviceId: mute of a 1:1 conversation. Keyed by the peer's
//     PRIMARY device (the identity), because the hub resolves every sender to
//     its primary before delivery; muting "Alice" must also silence Alice's
//     web companion.
// "off" is never stored: un-muting deletes the row, so the push hot path
// only ever finds rows that actually silence something.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ConversationMute
{
    public const string ModeOff = "off";
    public const string ModeBots = "bots";
    public const string ModeAll = "all";
    public static readonly string[] Modes = [ModeOff, ModeBots, ModeAll];

    public long Id { get; set; }

    /// <summary>The muting (recipient) device.</summary>
    public Guid DeviceId { get; set; }

    public Guid? GroupId { get; set; }

    public Guid? PeerPrimaryDeviceId { get; set; }

    /// <summary>"bots" (skip pushes for messages sent by a bot device) or "all".</summary>
    public string Mode { get; set; } = ModeAll;

    /// <summary>Null = until un-muted. A past value means "not muted" (no cleanup job needed).</summary>
    public DateTimeOffset? Until { get; set; }

    public DateTimeOffset UpdatedAt { get; set; }
}
