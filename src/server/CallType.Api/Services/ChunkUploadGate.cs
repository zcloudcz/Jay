// ---------------------------------------------------------------------------
// ChunkUploadGate.cs - Per-device cap on media chunk PUTs in flight
// ---------------------------------------------------------------------------
// The "media" rate limit is a fixed window of requests per minute; it does
// not bound how many requests are OPEN at once. A chunk PUT buffers up to one
// chunk, so a device trickling many PUTs could pin a lot of memory. This
// in-process counter bounds that per device (one App Service instance; with
// several instances the bound is per instance, which is still a bound).
// ---------------------------------------------------------------------------

namespace CallType.Api.Services;

public static class ChunkUploadGate
{
    private static readonly Dictionary<Guid, int> InFlight = new();

    /// <summary>Takes a slot for <paramref name="device"/>; false when it already has <paramref name="limit"/>.</summary>
    public static bool TryEnter(Guid device, int limit)
    {
        lock (InFlight)
        {
            InFlight.TryGetValue(device, out var count);
            if (count >= limit) return false;
            InFlight[device] = count + 1;
            return true;
        }
    }

    /// <summary>Releases a slot taken by <see cref="TryEnter"/>.</summary>
    public static void Exit(Guid device)
    {
        lock (InFlight)
        {
            if (!InFlight.TryGetValue(device, out var count)) return;
            if (count <= 1) InFlight.Remove(device);
            else InFlight[device] = count - 1;
        }
    }
}
