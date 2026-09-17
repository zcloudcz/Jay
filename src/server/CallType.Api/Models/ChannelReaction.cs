// ---------------------------------------------------------------------------
// ChannelReaction.cs — One emoji reaction of a device on a channel post
// ---------------------------------------------------------------------------
// Composite PK (PostId, DeviceId) enforces "one reaction per device per post"
// in the database. The API returns only per-emoji totals, never who reacted.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ChannelReaction
{
    public Guid PostId { get; set; }
    public Guid DeviceId { get; set; }

    /// <summary>
    /// A single emoji from the server-side whitelist. Max 16 UTF-16 chars
    /// because one visible emoji (grapheme) can be several code units.
    /// </summary>
    public string Emoji { get; set; } = string.Empty;

    public DateTimeOffset CreatedAt { get; set; }

    // Navigation properties
    public ChannelPost Post { get; set; } = null!;
}
