// ---------------------------------------------------------------------------
// AccountDevice.cs — Many-to-many join between Account and Device
// ---------------------------------------------------------------------------
// A single account can be logged in on multiple devices, and theoretically
// a device could be re-provisioned to a different account (after a wipe).
// The composite PK (AccountId, DeviceId) prevents duplicate links.
// ---------------------------------------------------------------------------

namespace ZMessanger.Api.Models;

public class AccountDevice
{
    public Guid AccountId { get; set; }
    public Guid DeviceId { get; set; }

    // Navigation properties
    public Account Account { get; set; } = null!;
    public Device Device { get; set; } = null!;
}
