// ---------------------------------------------------------------------------
// PushNotificationServiceTests.cs — Integration tests for push notification
// ---------------------------------------------------------------------------
// Tests the push notification service's behavior when devices have or lack
// push tokens. Since we cannot call the real FCM API in tests, we verify:
// 1. The service resolves the device from the DB correctly.
// 2. It handles missing devices, null tokens, and unknown platforms gracefully.
// 3. It skips push when the FCM server key is not configured (default in tests).
//
// The actual HTTP call to FCM is not tested here — that would require mocking
// the HttpClient pipeline or a fake FCM endpoint, which adds complexity for
// little value. The integration test for the push token endpoint (in
// DeviceEndpointsTests) covers the full flow of setting a token and verifying
// it was stored.
// ---------------------------------------------------------------------------

using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class PushNotificationServiceTests : IntegrationTestBase
{
    /// <summary>
    /// Resolves the singleton PushNotificationService from the test DI container.
    /// </summary>
    private PushNotificationService GetPushService()
    {
        return Factory.Services.GetRequiredService<PushNotificationService>();
    }

    [Fact]
    public async Task SendPushAsync_does_not_throw_when_device_not_found()
    {
        // A message may be queued for a device that was deleted between enqueue
        // and push. The service should handle this gracefully.
        var pushService = GetPushService();
        var nonExistentId = Guid.NewGuid();

        // Act & Assert — should complete without throwing.
        var act = () => pushService.SendPushAsync(nonExistentId);
        await act.Should().NotThrowAsync(
            "push to a non-existent device should be silently ignored");
    }

    [Fact]
    public async Task SendPushAsync_does_not_throw_when_device_has_no_push_token()
    {
        // Register a device (which has no push token by default), then
        // verify push is silently skipped.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();
        var pushService = GetPushService();

        // Act & Assert — device exists but has no PushToken.
        var act = () => pushService.SendPushAsync(deviceId);
        await act.Should().NotThrowAsync(
            "push to a device without a push token should be silently ignored");
    }

    [Fact]
    public async Task SendPushAsync_does_not_throw_when_fcm_key_not_configured()
    {
        // The test environment has no Push:FcmServerKey configured.
        // The service should log a warning and return without throwing.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        // Set a push token directly in the DB to trigger the FCM code path.
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var device = await db.Devices.FirstAsync(d => d.DeviceId == deviceId);
            device.PushToken = "fake-fcm-token";
            device.PushPlatform = "fcm";
            await db.SaveChangesAsync();
        }

        var pushService = GetPushService();

        // Act & Assert — FCM key is empty, so SendFcmAsync should return early.
        var act = () => pushService.SendPushAsync(deviceId);
        await act.Should().NotThrowAsync(
            "push should gracefully handle missing FCM server key");
    }

    [Fact]
    public async Task SendPushAsync_does_not_throw_for_apns_platform()
    {
        // APNs is not yet implemented. Verify it logs but doesn't throw.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var device = await db.Devices.FirstAsync(d => d.DeviceId == deviceId);
            device.PushToken = "fake-apns-token";
            device.PushPlatform = "apns";
            await db.SaveChangesAsync();
        }

        var pushService = GetPushService();

        // Act & Assert — APNs path should log and return without error.
        var act = () => pushService.SendPushAsync(deviceId);
        await act.Should().NotThrowAsync(
            "unimplemented APNs push should be handled gracefully");
    }

    [Fact]
    public async Task SendPushAsync_does_not_throw_for_unknown_platform()
    {
        // Edge case: a device has a push token with an unrecognized platform.
        // This could happen if a future client version sends a new platform
        // before the server is updated to handle it.
        var (deviceId, _, _) = await RegisterAndAuthenticateAsync();

        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var device = await db.Devices.FirstAsync(d => d.DeviceId == deviceId);
            device.PushToken = "some-token";
            device.PushPlatform = "web-push";
            await db.SaveChangesAsync();
        }

        var pushService = GetPushService();

        // Act & Assert — unknown platforms should be logged, not crash.
        var act = () => pushService.SendPushAsync(deviceId);
        await act.Should().NotThrowAsync(
            "unknown push platform should be handled gracefully");
    }
}
