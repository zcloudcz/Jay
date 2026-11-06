import 'dart:async';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:flutter/foundation.dart';

import '../../core/crypto/key_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import 'device_service.dart';
import 'link_code.dart';

/// v1 links only an empty device (decision 3): no contacts, no
/// conversations. Merging two histories is out of scope, and an empty device
/// that confirms the wrong primary exposes nothing that already exists.
Future<bool> isEmptyDevice(AppDatabase db) async =>
    (await (db.select(db.contacts)..limit(1)).get()).isEmpty &&
    (await (db.select(db.conversations)..limit(1)).get()).isEmpty;

enum PrimaryLinkState { idle, working, waitingForConsent, linked, mismatch, failed }

/// Primary side of spec Part A "Linking a device", steps 2, 3 and 5.
class PrimaryLinkController extends ChangeNotifier {
  PrimaryLinkController({
    required DeviceService devices,
    required ApiClient apiClient,
    required SignalRClient signalRClient,
    this.consentTimeout = const Duration(minutes: 3),
  }) : _devices = devices,
       _api = apiClient,
       _signalR = signalRClient;

  final DeviceService _devices;
  final ApiClient _api;
  final SignalRClient _signalR;

  /// How long the primary waits for the user to confirm on the new device.
  /// The clock starts after the offer is sent, and the total stays well below
  /// the hub's 10 minute consent record, so the PUT that follows finds it.
  /// The new device gives up a little later (see [CompanionLinkController]).
  final Duration consentTimeout;

  PrimaryLinkState _state = PrimaryLinkState.idle;
  PrimaryLinkState get state => _state;
  bool _disposed = false;
  bool _cancelled = false;
  Completer<String>? _consent;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Stops a link in progress. WHY it exists: closing the dialog used to
  /// leave the wait and the consent listener running, so a consent arriving
  /// later still signed and uploaded a list the user had walked away from.
  void cancel() {
    _cancelled = true;
    _subscription?.cancel();
    _subscription = null;
    final pending = _consent;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('cancelled'));
    }
  }

  Future<void> link(String scanned) async {
    if (_state == PrimaryLinkState.working ||
        _state == PrimaryLinkState.waitingForConsent) {
      return;
    }
    final code = LinkCode.parse(scanned);
    if (code == null) {
      _set(PrimaryLinkState.failed);
      return;
    }
    _set(PrimaryLinkState.working);
    try {
      final bundle = await _api.getKeyBundle(code.deviceId);
      final identityKey = bundle['identityKey'] as String;
      final signingKey = bundle['signingKey'] as String;
      // Step 2, BEFORE anything is sent: the keys the server hands out must
      // be the keys the QR code (the out-of-band channel) named.
      if (linkFingerprint(identityKey, signingKey) != code.fingerprint) {
        _set(PrimaryLinkState.mismatch);
        return;
      }
      if (_cancelled) return;
      final consent = _consent = Completer<String>();
      // Listen before the offer goes out, or a fast answer is missed.
      _subscription = _signalR.onLinkConsent.listen((event) {
        final sig = event['consentSig'];
        if ((event['deviceId'] as String?)?.toLowerCase() == code.deviceId &&
            sig is String &&
            !consent.isCompleted) {
          consent.complete(sig);
        }
      });
      await _signalR.sendLinkOffer(code.deviceId);
      _set(PrimaryLinkState.waitingForConsent);
      final consentSig = await consent.future.timeout(consentTimeout);
      if (_cancelled) return;
      final self = _devices.directory.selfDeviceId;
      // The consent must be signed by the key the QR code named, for THIS
      // primary; the hub relays it but cannot forge it.
      if (!await verifyDeviceLinkConsent(
        consentSig: consentSig,
        companionSigningKey: signingKey,
        primaryDeviceId: self,
        companionDeviceId: code.deviceId,
      )) {
        _set(PrimaryLinkState.failed);
        return;
      }
      // Last gate before anything is signed and uploaded.
      if (_cancelled) return;
      await _devices.addCompanion(
        DeviceListEntry(
          deviceId: code.deviceId,
          identityKey: identityKey,
          signingKey: signingKey,
          consentSig: consentSig,
        ),
      );
      _set(PrimaryLinkState.linked);
    } catch (_) {
      if (!_cancelled) _set(PrimaryLinkState.failed);
    } finally {
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  void _set(PrimaryLinkState state) {
    _state = state;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

enum CompanionLinkState {
  loading,
  notEmpty,
  showingCode,
  offered,
  waiting,
  linked,
  failed,
}

/// New-device side of spec Part A "Linking a device", steps 1, 4 and 6.
class CompanionLinkController extends ChangeNotifier {
  CompanionLinkController({
    required AppDatabase database,
    required DeviceService devices,
    required KeyManager keyManager,
    required SignalRClient signalRClient,
    this.waitTimeout = const Duration(minutes: 4),
  }) : _db = database,
       _devices = devices,
       _keys = keyManager,
       _signalR = signalRClient {
    _devices.addListener(_onDevices);
  }

  final AppDatabase _db;
  final DeviceService _devices;
  final KeyManager _keys;
  final SignalRClient _signalR;

  /// How long to wait for the primary to finish after consenting. Longer than
  /// the primary's own consent wait, so when this fires the primary has
  /// already given up too and nothing can still link us.
  final Duration waitTimeout;
  Timer? _waitTimer;
  StreamSubscription<Map<String, dynamic>>? _offers;
  bool _disposed = false;

  CompanionLinkState _state = CompanionLinkState.loading;
  CompanionLinkState get state => _state;

  /// The QR code content, set once the device is known to be empty.
  String? code;
  String? offeredPrimary;

  /// The primary's handle as the hub reported it (the user compares it with
  /// the phone in their hand); falls back to the id on an old server.
  String? offeredHandle;

  Future<void> start() async {
    // Restartable: after "disconnect and link" (link UX, A3) the same screen
    // starts again on the now empty device. The old offer listener goes first,
    // or an offer would be counted twice.
    final old = _offers;
    _offers = null;
    if (old != null) await old.cancel();
    _leaveWaiting();
    code = null;
    offeredPrimary = null;
    offeredHandle = null;
    if (_state != CompanionLinkState.loading) _set(CompanionLinkState.loading);
    // Not registered yet: there is no device id to put in a code.
    if (!_devices.isOpen) {
      _set(CompanionLinkState.failed);
      return;
    }
    if (!await isEmptyDevice(_db)) {
      _set(CompanionLinkState.notEmpty);
      return;
    }
    final bundle = await _keys.getSignedIdentityBundle();
    code = LinkCode(
      _devices.directory.selfDeviceId,
      linkFingerprint(bundle['identityKey']!, bundle['signingKey']!),
    ).toString();
    _offers = _signalR.onLinkOffer.listen((event) {
      final primary = (event['primaryDeviceId'] as String?)?.toLowerCase();
      // Offers count only while the code is on screen and nothing was
      // accepted yet: a later offer must not replace the one being confirmed.
      if (primary == null || _state != CompanionLinkState.showingCode) return;
      offeredPrimary = primary;
      offeredHandle = event['userHandle'] as String? ?? primary;
      _set(CompanionLinkState.offered);
    });
    _set(CompanionLinkState.showingCode);
  }

  /// Cancel / retry: back to the code. Also leaves the waiting state, which
  /// has no other exit when the primary never finishes.
  void reject() {
    // A failure before a code existed (not registered) has nothing to show.
    if (code == null) return;
    _leaveWaiting();
    offeredPrimary = null;
    offeredHandle = null;
    _set(CompanionLinkState.showingCode);
  }

  void _leaveWaiting() {
    _waitTimer?.cancel();
    _waitTimer = null;
    if (_state == CompanionLinkState.waiting) {
      // Hints from that primary must not link us after the user cancelled.
      _devices.cancelExpectedLink();
    }
  }

  Future<void> accept() async {
    final primary = offeredPrimary;
    if (primary == null || _state != CompanionLinkState.offered) return;
    // Leave "offered" BEFORE the first await: a second tap or a cancel during
    // the checks below then sees "waiting" and cannot start a second consent.
    _set(CompanionLinkState.waiting);
    // Re-checked: a message may have arrived while the question was open.
    if (!await isEmptyDevice(_db)) {
      if (_state == CompanionLinkState.waiting) {
        _set(CompanionLinkState.notEmpty);
      }
      return;
    }
    if (_state != CompanionLinkState.waiting) return;
    _devices.expectLink(primary);
    _waitTimer?.cancel();
    _waitTimer = Timer(waitTimeout, () {
      if (_state != CompanionLinkState.waiting) return;
      _leaveWaiting();
      _set(CompanionLinkState.failed);
    });
    await _db
        .into(_db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: linkedPrimaryHandleKey,
            value: offeredHandle ?? primary,
          ),
        );
    // Cancelled while the handle was being stored.
    if (_state != CompanionLinkState.waiting) return;
    try {
      // The consent names the primary, so it can only be signed now that the
      // offer told us which primary it is (spec Part A, step 4).
      await _signalR.sendLinkConsent(
        primary,
        await signDeviceLinkConsent(
          companionSigningKey: await _keys.getSigningKeyPair(),
          primaryDeviceId: primary,
          companionDeviceId: _devices.directory.selfDeviceId,
        ),
      );
    } catch (e) {
      // The hub records the consent BEFORE it relays it (constraint 7):
      // link_target_offline does not undo it, so keep waiting for the list.
      if (!e.toString().contains('link_target_offline')) {
        _set(CompanionLinkState.failed);
      }
    }
  }

  void _onDevices() {
    if (_state == CompanionLinkState.waiting &&
        _devices.isCompanion &&
        _devices.directory.selfIdentityId == offeredPrimary) {
      _waitTimer?.cancel();
      _set(CompanionLinkState.linked);
    }
  }

  void _set(CompanionLinkState state) {
    _state = state;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _offers?.cancel();
    _waitTimer?.cancel();
    _devices.removeListener(_onDevices);
    super.dispose();
  }
}
