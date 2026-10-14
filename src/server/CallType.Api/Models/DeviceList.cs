// ---------------------------------------------------------------------------
// DeviceList.cs - multi-device: the signed list of an identity's companions
// ---------------------------------------------------------------------------
// The server is storage and routing only. Payload + Signature are the exact
// bytes the primary device signed; clients verify them, the server never
// does and is never trusted to. DeviceListMember is derived from the payload
// on every write and exists purely so the hub can answer "which devices
// belong to this identity" without parsing JSON on the hot path.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class DeviceList
{
    public Guid PrimaryDeviceId { get; set; }

    /// <summary>Only grows. Also the EF concurrency token (two writers race, one gets 409).</summary>
    public int Version { get; set; }

    public byte[] Payload { get; set; } = [];
    public byte[] Signature { get; set; } = [];
    public DateTimeOffset UpdatedAt { get; set; }

    public List<DeviceListMember> Members { get; set; } = [];
}

public class DeviceListMember
{
    /// <summary>Primary key: a device is a companion of at most one identity.</summary>
    public Guid DeviceId { get; set; }

    public Guid PrimaryDeviceId { get; set; }
}
