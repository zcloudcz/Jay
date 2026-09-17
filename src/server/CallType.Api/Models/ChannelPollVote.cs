// ---------------------------------------------------------------------------
// ChannelPollVote.cs — One vote of a device in a poll post
// ---------------------------------------------------------------------------
// Composite PK (PostId, DeviceId) enforces "one vote per device per poll";
// changing a vote updates the row. The API returns only per-option totals.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class ChannelPollVote
{
    public Guid PostId { get; set; }
    public Guid DeviceId { get; set; }

    /// <summary>Zero-based index into the poll options stored in ChannelPost.Body.</summary>
    public int OptionIndex { get; set; }

    // Navigation properties
    public ChannelPost Post { get; set; } = null!;
}
