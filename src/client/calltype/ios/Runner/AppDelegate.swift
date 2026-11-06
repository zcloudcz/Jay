import Flutter
import UIKit
import UserNotifications

/// Native side of notifications (spec 2026-11-06, section 2, iOS):
/// - the APNs device token comes straight from UIKit, NOT from Firebase, over
///   the method channel `cz.zcloud.jay/apns` (see ApnsPushProvider in Dart);
/// - taps on SERVER pushes are forwarded to Dart with their data
///   (`type`, `conversationId`, `v`) so the app opens that conversation.
///   Taps on local notifications are left to flutter_local_notifications.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsChannel: FlutterMethodChannel?
  /// Dart calls waiting for `didRegisterForRemoteNotifications...`.
  private var pendingRegistrations: [FlutterResult] = []
  /// A server-push tap Dart has not received yet (cold start: the tap can
  /// arrive before the Dart side listens). Handed out by
  /// `takeLaunchNotification` or cleared once a live delivery succeeded.
  private var pendingTap: [String: String]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications (README, iOS setup) and by the
    // server-push tap handling below: FlutterAppDelegate forwards every
    // callback to the plugins.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // With the UIScene lifecycle the engine is created implicitly, so an
    // application-level channel is registered here, not in didFinishLaunching.
    let channel = FlutterMethodChannel(
      name: "cz.zcloud.jay/apns",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleApnsCall(call, result: result)
    }
    apnsChannel = channel
  }

  private func handleApnsCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "register":
      // The notification permission was requested before (Dart, through
      // flutter_local_notifications). The token arrives asynchronously.
      pendingRegistrations.append(result)
      UIApplication.shared.registerForRemoteNotifications()
    case "takeLaunchNotification":
      result(pendingTap)
      pendingTap = nil
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // Contract 1.1: `apns` tokens are sent as lowercase hex.
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    let waiting = pendingRegistrations
    pendingRegistrations = []
    if waiting.isEmpty {
      // Unsolicited (token rotated by the OS): Dart re-registers it.
      apnsChannel?.invokeMethod("onToken", arguments: hex)
    }
    waiting.forEach { $0(hex) }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // Typical on the simulator or a build signed without the
    // aps-environment entitlement: Dart reports "not configured" and local
    // notifications keep working.
    let waiting = pendingRegistrations
    pendingRegistrations = []
    waiting.forEach {
      $0(FlutterError(code: "apns_unavailable", message: error.localizedDescription, details: nil))
    }
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // Only server pushes: a local notification's tap is reported by
    // flutter_local_notifications through the super call below.
    if response.notification.request.trigger is UNPushNotificationTrigger {
      let info = response.notification.request.content.userInfo
      var data: [String: String] = [:]
      for key in ["type", "conversationId", "v"] {
        if let value = info[key] as? String { data[key] = value }
      }
      deliverTap(data)
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  private func deliverTap(_ data: [String: String]) {
    pendingTap = data
    guard let channel = apnsChannel else { return }
    channel.invokeMethod("onNotificationTap", arguments: data) { [weak self] result in
      // Delivered only when Dart has a handler; otherwise keep it for
      // takeLaunchNotification so a cold-start tap is not lost.
      if result is FlutterError { return }
      if let object = result as? NSObject, object === FlutterMethodNotImplemented { return }
      self?.pendingTap = nil
    }
  }
}
