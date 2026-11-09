import AVFAudio
import CallKit
import CryptoKit
import Flutter
import PushKit
import UIKit
import UserNotifications
import WebRTC
import flutter_callkit_incoming

/// Native side of notifications (spec 2026-11-06, section 2, iOS):
/// - the APNs device token comes straight from UIKit, NOT from Firebase, over
///   the method channel `cz.zcloud.jay/apns` (see ApnsPushProvider in Dart);
/// - taps on SERVER pushes are forwarded to Dart with their data
///   (`type`, `conversationId`, `v`) so the app opens that conversation.
///   Taps on local notifications are left to flutter_local_notifications.
///
/// Call ringing on a closed app (spec 2026-11-06-call-ringing, section 2):
/// PushKit VoIP pushes are reported to CallKit through flutter_callkit_incoming
/// (its README / example AppDelegate), synchronously in the PushKit callback
/// as iOS requires. The Dart side (CallRingCoordinator) takes over from the
/// CallKit events; WebRTC audio runs on the session CallKit activates.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  PKPushRegistryDelegate, CallkitIncomingAppDelegate
{
  private var apnsChannel: FlutterMethodChannel?
  /// Dart calls waiting for `didRegisterForRemoteNotifications...`.
  private var pendingRegistrations: [FlutterResult] = []
  /// A server-push tap Dart has not received yet (cold start: the tap can
  /// arrive before the Dart side listens). Handed out by
  /// `takeLaunchNotification` or cleared once a live delivery succeeded.
  private var pendingTap: [String: String]?
  /// PushKit registry; must live as long as the app.
  private var voipRegistry: PKPushRegistry?
  /// The last VoIP token: PushKit can deliver it before the plugins are
  /// registered (implicit engine), so it is handed over again afterwards.
  private var voipToken: String?
  /// Used only when a VoIP push arrives before flutter_callkit_incoming is
  /// registered: iOS terminates an app that does not report a VoIP push.
  private lazy var fallbackProvider: CXProvider = {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallsPerCallGroup = 1
    configuration.includesCallsInRecents = false
    return CXProvider(configuration: configuration)
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications (README, iOS setup) and by the
    // server-push tap handling below: FlutterAppDelegate forwards every
    // callback to the plugins.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    // PushKit (flutter_callkit_incoming README / PUSHKIT.md), registered at
    // launch so the VoIP push that launched the app is delivered.
    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [PKPushType.voIP]
    voipRegistry = registry
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
    if let token = voipToken {
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
    }
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
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
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

  // MARK: - PushKit (call ringing spec, section 2, iOS)

  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
  ) {
    // Lowercase hex like the APNs token; Dart sends it to
    // PUT /devices/{id}/voip-token on the plugin's token event.
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    // Empty token: Dart sends DELETE /devices/{id}/voip-token.
    voipToken = ""
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    // Payload (spec 1.3): {"aps":{}, "type", "callId", "conversationId", "v"}.
    // No caller data (R4): CallKit shows "Jay". Every VoIP push MUST be
    // reported to CallKit, even a malformed one.
    let info = payload.dictionaryPayload
    let callId = (info["callId"] as? String) ?? UUID().uuidString.lowercased()
    let uuid = AppDelegate.ringUUID(for: callId)

    guard let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance else {
      // The Flutter engine (and with it the plugin) is not up yet. Report and
      // end the call at once so iOS does not terminate the app; the caller's
      // hangup reaches the app later as a missed call.
      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: "Jay")
      update.localizedCallerName = "Jay"
      update.hasVideo = false
      fallbackProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
        self?.fallbackProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        completion()
      }
      return
    }

    let data = flutter_callkit_incoming.Data(
      id: uuid.uuidString.lowercased(), nameCaller: "Jay", handle: "Jay", type: 0)
    data.appName = "Jay"
    data.handleType = "generic"
    data.supportsVideo = false
    data.maximumCallGroups = 1
    data.maximumCallsPerCallGroup = 1
    data.supportsDTMF = false
    data.supportsHolding = false
    data.supportsGrouping = false
    data.supportsUngrouping = false
    // R9: keep Jay calls out of the Phone app's Recents (privacy).
    data.includesCallsInRecents = false
    data.audioSessionMode = "voiceChat"
    // The caller rings for 45 s; so does CallKit.
    data.duration = 45000
    // The plugin's missed-call notification is not localized; the Dart side
    // shows a localized one instead.
    data.isShowMissedCallNotification = false
    var extra: [String: Any] = [
      "callId": callId,
      "ts": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    if let conversationId = info["conversationId"] as? String {
      extra["conversationId"] = conversationId
    }
    data.extra = extra as NSDictionary
    plugin.showCallkitIncoming(data, fromPushKit: true) {
      completion()
    }
  }

  /// The CallKit UUID of a call: the call id itself when it is a UUID (always
  /// true for calls the app starts), else a UUIDv5 (SHA-1, RFC 4122) of it in
  /// the URL namespace. Must match `ringIdFor` in lib/features/calls/call_ring.dart.
  static func ringUUID(for callId: String) -> UUID {
    if let uuid = UUID(uuidString: callId) {
      return uuid
    }
    // NAMESPACE_URL 6ba7b811-9dad-11d1-80b4-00c04fd430c8
    var input: [UInt8] = [
      0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
      0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
    ]
    input.append(contentsOf: Array(callId.utf8))
    var h: [UInt8] = Array(Array(Insecure.SHA1.hash(data: input)).prefix(16))
    h[6] = (h[6] & 0x0F) | 0x50
    h[8] = (h[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
        h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]
      ))
  }

  // MARK: - CallkitIncomingAppDelegate (flutter_callkit_incoming README)

  func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    // WebRTC must not start its own audio before CallKit activates the
    // session (README "Use if using WebRTC"); didActivateAudioSession turns
    // it on. Only for CallKit calls: in-app calls keep automatic audio.
    RTCAudioSession.sharedInstance().useManualAudio = true
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    action.fulfill()
  }

  func onDecline(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onEnd(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
    restoreAutomaticAudio()
  }

  func onTimeOut(_ call: Call) {
  }

  func didActivateAudioSession(_ audioSession: AVAudioSession) {
    RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
    RTCAudioSession.sharedInstance().isAudioEnabled = true
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    restoreAutomaticAudio()
  }

  func providerDidReset() {
    restoreAutomaticAudio()
  }

  /// Back to WebRTC's own audio handling for the next in-app call.
  private func restoreAutomaticAudio() {
    RTCAudioSession.sharedInstance().isAudioEnabled = true
    RTCAudioSession.sharedInstance().useManualAudio = false
  }
}
