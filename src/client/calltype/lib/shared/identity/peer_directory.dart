import 'package:flutter/foundation.dart';

/// Verification state of a peer's identity key (G §4.3, S6).
enum IdentityState {
  /// Pinned on first use, never compared out of band.
  unverified,

  /// Compared out of band (safety number / QR) and unchanged since.
  verified,

  /// The key changed and the change was not accepted yet; never verified.
  changedUnverified,

  /// The key changed after the contact HAD been verified — the case that
  /// deserves the loudest warning.
  changedVerified,
}

/// "Who is this device" for every widget that shows a person: chat bubbles,
/// the chat list, calls, notifications (contracts K8, G §4.3 point 3).
///
/// Synchronous getters on purpose — `build()` cannot await. The real
/// implementation (G3, `PeerDirectoryService`) keeps a cache fed by drift
/// `watch()` streams over `Contacts`, `PeerProfiles` and `BlockedDevices`
/// and notifies listeners when it changes. Code without a widget tree reads
/// blocking through `isDeviceBlocked` (calltype_core block_list.dart).
abstract class PeerDirectory implements Listenable {
  /// Name to show, in the order of G R2: my nickname for the contact →
  /// the peer's declared profile name (prefixed `~` for a non-contact) →
  /// handle → shortened device id.
  String displayName(String deviceId);

  /// `CT-XXXX-XXXX`, if known.
  String? handle(String deviceId);

  /// 48×48 JPEG that arrived inline with the profile.
  Uint8List? avatarThumb(String deviceId);

  /// 256×256 JPEG, once downloaded.
  Uint8List? avatarImage(String deviceId);
  bool isContact(String deviceId);
  bool isBlocked(String deviceId);
  IdentityState identityState(String deviceId);
}

/// Placeholder until G3 lands (and for widget tests that do not care about
/// names): knows nothing, so every device shows its shortened id — the same
/// thing the UI showed before profiles existed. Never notifies.
class FallbackPeerDirectory extends ChangeNotifier implements PeerDirectory {
  FallbackPeerDirectory({Map<String, String> handles = const {}})
    : _handles = handles;

  final Map<String, String> _handles;

  @override
  String displayName(String deviceId) =>
      _handles[deviceId] ??
      (deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId);

  @override
  String? handle(String deviceId) => _handles[deviceId];

  @override
  Uint8List? avatarThumb(String deviceId) => null;

  @override
  Uint8List? avatarImage(String deviceId) => null;

  @override
  bool isContact(String deviceId) => false;

  @override
  bool isBlocked(String deviceId) => false;

  @override
  IdentityState identityState(String deviceId) => IdentityState.unverified;
}
