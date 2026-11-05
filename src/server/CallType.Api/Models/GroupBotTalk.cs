// ---------------------------------------------------------------------------
// GroupBotTalk.cs - Per-group "bot conversation" setting (owned by Group)
// ---------------------------------------------------------------------------
// The server only stores and validates this; it cannot enforce it because it
// never sees message content. Every bot reads the setting (GET /groups/{id})
// and refuses bot messages the setting does not allow, so a misbehaving bot
// is contained by the receiving bot (see the design doc
// docs/superpowers/specs/2026-11-05-bot-conversations-design.md).
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class GroupBotTalk
{
    public const string ModeOff = "off";
    public const string ModeAll = "all";
    public const string ModeSelected = "selected";
    public static readonly string[] Modes = [ModeOff, ModeAll, ModeSelected];

    public const int DefaultMaxBotTurns = 5;
    public const int MinMaxBotTurns = 1;
    public const int MaxMaxBotTurns = 50;
    public const int DefaultPauseMinutes = 30;
    public const int MinPauseMinutes = 0;
    public const int MaxPauseMinutes = 1440;

    /// <summary>"off" (default) | "all" | "selected". A string, like GroupMember.Role, so a new mode needs no enum migration.</summary>
    public string Mode { get; set; } = ModeOff;

    /// <summary>
    /// Bot devices allowed to talk when Mode = "selected". Kept (not cleared)
    /// for the other modes so an admin can switch Selected -> All -> Selected
    /// without re-ticking the list. Stored as a Postgres uuid[] because it is
    /// small (bounded by the member cap) and always read whole with the group.
    /// </summary>
    public List<Guid> AllowedBotDeviceIds { get; set; } = [];

    /// <summary>Max bot messages in a row without a human (D3).</summary>
    public int MaxBotTurns { get; set; } = DefaultMaxBotTurns;

    /// <summary>Pause between two bot-only exchanges, in minutes (D4).</summary>
    public int PauseMinutes { get; set; } = DefaultPauseMinutes;

    /// <summary>Admin device that last changed the setting; null = never changed.</summary>
    public Guid? UpdatedBy { get; set; }

    /// <summary>Null = never changed (the contract exposes it as null).</summary>
    public DateTimeOffset? UpdatedAt { get; set; }
}
