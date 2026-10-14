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
    this.consentTimeout = const Duration(minutes: 2),
  }) : _devices = devices,
       _api = apiClient,
       _signalR = signalRClient;

  final DeviceService _devices;
  final ApiClient _api;
  final SignalRClient _signalR;

  /// How long the primary waits for the user to confirm on the new device.
  /// Shorter than the hub's 10 minute consent record, so the PUT that
  /// follows always finds it.
  final Duration consentTimeout;

  PrimaryLinkState _state = PrimaryLinkState.idle;
  PrimaryLinkState get state => _state;
  bool _disposed = false;

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
    StreamSubscription<Map<String, dynamic>>? subscription;
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
      final consent = Completer<String>();
      // Listen before the offer goes out, or a fast answer is missed.
      subscription = _signalR.onLinkConsent.listen((event) {
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
      _set(PrimaryLinkState.failed);
    } finally {
      await subscription?.cancel();
    }
  }

  void _set(PrimaryLinkState state) {
    _state = state;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
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

  void reject() {
    offeredPrimary = null;
    offeredHandle = null;
    _set(CompanionLinkState.showingCode);
  }

  Future<void> accept() async {
    final primary = offeredPrimary;
    if (primary == null || _state != CompanionLinkState.offered) return;
    // Re-checked: a message may have arrived while the question was open.
    if (!await isEmptyDevice(_db)) {
      _set(CompanionLinkState.notEmpty);
      return;
    }
    _set(CompanionLinkState.waiting);
    _devices.expectLink(primary);
    await _db
        .into(_db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: linkedPrimaryHandleKey,
            value: offeredHandle ?? primary,
          ),
        );
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
    _devices.removeListener(_onDevices);
    super.dispose();
  }
}
