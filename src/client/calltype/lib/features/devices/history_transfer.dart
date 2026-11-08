import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart' show GZipDecoder, GZipEncoder;
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/history_transfer.dart';
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:flutter/foundation.dart';

import 'package:calltype_core/storage/database.dart';
import '../backup/backup_controller.dart' show buildBackupData;
import '../backup/backup_import.dart';
import '../chat/message_inbox_service.dart' show MessageProcessingQueue;
import '../contacts/contact_sync.dart' show OwnControlMessage;
import '../media/media_crypto.dart' show newMediaKey;
import '../media/media_message.dart';
import '../media/media_service.dart';
import 'own_device_sender.dart';

/// File name of the archive in the media store (never shown).
const historyArchiveName = 'history.json.gz';
const _archiveMime = 'application/gzip';

enum HistoryTransferRole { none, target, source }

enum HistoryTransferPhase {
  idle,

  /// Target: the QR / text code is shown, waiting for the source.
  showingCode,

  /// Source: building the archive for the estimate.
  preparing,

  /// Source: the estimate is shown, waiting for the user's confirmation.
  confirm,
  uploading,

  /// Source: uploaded and the key sent; waiting for the target's "done".
  waitingForTarget,
  downloading,
  importing,
  done,
  failed,
}

enum HistoryTransferError {
  /// Not a history transfer code.
  invalidCode,

  /// The code names a device that is not one of ours (or this device).
  notOwnDevice,

  /// The archive is above the media cap of this platform.
  tooLarge,

  /// The key could not be unwrapped: the offer was not made for the code
  /// this device shows.
  wrongKey,

  /// Size or SHA-256 of the downloaded archive do not match.
  damaged,

  /// The archive is gone from the relay.
  expired,

  /// The archive could not be read or imported.
  importFailed,

  /// The code was shown too long; a new one is needed.
  timeout,

  /// Upload, download or the key delivery failed.
  network,
}

/// History transfer between own devices (spec 2026-11-08-contact-sync):
/// one archive, end-to-end encrypted, through the media relay; its key goes
/// to the target only, wrapped for the ephemeral key in the target's QR
/// code. One transfer at a time per device, in memory only.
class HistoryTransferService extends ChangeNotifier {
  HistoryTransferService({
    required AppDatabase database,
    required OwnDeviceSender sender,
    required DeviceDirectory Function() directory,
    required Stream<OwnControlMessage> controls,
    MediaService? media,
  }) : _db = database,
       _sender = sender,
       _directory = directory,
       _controls = controls,
       _mediaOverride = media;

  final AppDatabase _db;
  final OwnDeviceSender _sender;
  final DeviceDirectory Function() _directory;
  final Stream<OwnControlMessage> _controls;
  final MediaService? _mediaOverride;
  StreamSubscription<OwnControlMessage>? _subscription;

  MediaService get _media => _mediaOverride ?? MediaService.instance;

  HistoryTransferRole _role = HistoryTransferRole.none;
  HistoryTransferPhase _phase = HistoryTransferPhase.idle;
  HistoryTransferError? _error;
  bool _disposed = false;

  // Target side.
  SimpleKeyPair? _keyPair;
  String? _code;
  Timer? _expiry;
  MediaInfo? _download;

  // Source side.
  HistoryTransferCode? _target;
  Uint8List? _archive;
  int _chats = 0;
  MediaInfo? _uploaded;

  String? _transferId;
  int _importedMessages = 0;

  HistoryTransferRole get role => _role;
  HistoryTransferPhase get phase => _phase;
  HistoryTransferError? get error => _error;

  /// Target: the code to show as QR and as copyable text.
  String? get code => _code;

  /// Source: the device the archive goes to.
  String? get targetDeviceId => _target?.targetDeviceId;

  /// Source: chats and archive bytes of the estimate.
  int get chatCount => _chats;
  int get archiveBytes => _archive?.length ?? _uploaded?.size ?? 0;

  /// Target: messages in the imported archive (shown when done).
  int get importedMessages => _importedMessages;

  /// 0..1 of the running upload or download; null when unknown.
  double? get progress => switch (_phase) {
    HistoryTransferPhase.uploading => _media.uploadOf(_uploadKey)?.fraction,
    HistoryTransferPhase.downloading =>
      _download == null ? null : _media.downloadOf(_download!.id)?.fraction,
    _ => null,
  };

  bool get busy =>
      _phase != HistoryTransferPhase.idle &&
      _phase != HistoryTransferPhase.done &&
      _phase != HistoryTransferPhase.failed;

  String get _uploadKey => 'history-${_transferId ?? ''}';

  void start() {
    _subscription ??= _controls.listen((message) {
      switch (message.type) {
        case historyTransferType:
          unawaited(_onOffer(message));
        case historyTransferDoneType:
          unawaited(_onDone(message));
      }
    });
  }

  // ---------------------------------------------------------------- target

  /// Shows a new code on this device (the one that should receive). Any
  /// earlier transfer is cancelled first.
  Future<String> startReceiving() async {
    await cancel();
    final pair = await newHistoryTransferKeyPair();
    final transferId = newHistoryTransferId();
    final code = HistoryTransferCode(
      targetDeviceId: _directory().selfDeviceId,
      transferId: transferId,
      targetPublicKey: await historyTransferPublicKey(pair),
    ).encode();
    _keyPair = pair;
    _transferId = transferId;
    _code = code;
    _role = HistoryTransferRole.target;
    _expiry = Timer(historyTransferCodeLifetime, () {
      if (_phase == HistoryTransferPhase.showingCode) {
        _fail(HistoryTransferError.timeout);
      }
    });
    _set(HistoryTransferPhase.showingCode);
    return code;
  }

  Future<void> _onOffer(OwnControlMessage message) async {
    final offer = HistoryTransferOffer.decode(message.body);
    final pair = _keyPair;
    // Every other own device ignores a transfer it did not create, and a
    // code that is no longer shown takes nothing.
    if (offer == null ||
        pair == null ||
        _role != HistoryTransferRole.target ||
        _phase != HistoryTransferPhase.showingCode ||
        offer.transferId != _transferId ||
        offer.targetDeviceId.toLowerCase() != _directory().selfDeviceId) {
      return;
    }
    _expiry?.cancel();
    final keys = await unwrapArchiveKey(
      target: pair,
      sourcePublicKey: offer.sourceEphemeralKey,
      wrapped: offer.wrappedKey,
    );
    // The ephemeral key is single use.
    _keyPair = null;
    if (keys == null) {
      _fail(HistoryTransferError.wrongKey);
      return;
    }
    if (offer.size > _media.maxBytes) {
      _fail(HistoryTransferError.tooLarge);
      return;
    }
    final info = MediaInfo(
      id: offer.mediaId,
      kind: MediaKind.file,
      name: historyArchiveName,
      mime: _archiveMime,
      size: offer.size,
      sha256: offer.sha256,
      key: keys.key,
      nonce: keys.nonce,
    );
    _download = info;
    _media.addListener(_onMediaProgress);
    _set(HistoryTransferPhase.downloading);
    try {
      await _media.download(info);
    } finally {
      _media.removeListener(_onMediaProgress);
    }
    if (_download != info) return; // cancelled meanwhile
    final outcome = _media.downloadOf(info.id)?.phase;
    final bytes = outcome == null ? await _media.bytesOf(info) : null;
    if (bytes == null) {
      await _media.deleteLocal(info.id);
      _fail(switch (outcome) {
        MediaPhase.damaged => HistoryTransferError.damaged,
        MediaPhase.expired => HistoryTransferError.expired,
        _ => HistoryTransferError.network,
      });
      return;
    }
    _set(HistoryTransferPhase.importing);
    try {
      final json = jsonDecode(utf8.decode(GZipDecoder().decodeBytes(bytes)));
      _importedMessages = json is Map && json['messages'] is List
          ? (json['messages'] as List).length
          : 0;
      await MessageProcessingQueue.forDatabase(
        _db,
      ).run(() => importBackup(_db, json, mergeContacts: true));
    } catch (_) {
      _fail(HistoryTransferError.importFailed);
      return;
    } finally {
      // The decrypted archive is a temporary file only.
      await _media.deleteLocal(info.id);
    }
    _download = null;
    // Lets the source delete the relay copy at once instead of waiting for
    // the retention. Best effort: a lost "done" costs only storage time.
    await _sender.send(
      historyTransferDoneType,
      HistoryTransferDone(offer.transferId).encode(),
    );
    _set(HistoryTransferPhase.done);
  }

  // ---------------------------------------------------------------- source

  /// Source, step 1: checks a scanned or pasted [raw] code and builds the
  /// archive for the estimate. Returns the error, or null when the
  /// confirmation can be shown.
  Future<HistoryTransferError?> prepare(String raw) async {
    await cancel();
    final code = HistoryTransferCode.parse(raw);
    if (code == null) return _fail(HistoryTransferError.invalidCode);
    _role = HistoryTransferRole.source;
    _target = code;
    _transferId = code.transferId;
    final directory = _directory();
    final target = code.targetDeviceId.toLowerCase();
    // Only a device in our own VERIFIED list, never this one: the server
    // cannot slip in a reader through a forged code.
    final own = await directory.devicesOf(directory.selfIdentityId);
    if (target == directory.selfDeviceId || !own.contains(target)) {
      return _fail(HistoryTransferError.notOwnDevice);
    }
    _set(HistoryTransferPhase.preparing);
    // Business is primary-only in v1: a companion gets the headers (from
    // contact sync) but not the messages.
    final toPrimary = target == directory.selfIdentityId;
    final data = await buildBackupData(
      _db,
      withMessages: toPrimary ? null : (c) => c.organizationId == null,
    );
    final archive = Uint8List.fromList(
      GZipEncoder().encodeBytes(utf8.encode(jsonEncode(data))),
    );
    if (_target != code) return null; // cancelled meanwhile
    final messages = data['messages'] as List;
    _chats = {for (final m in messages) (m as Map)['conversationId']}.length;
    _archive = archive;
    if (archive.length > _media.maxBytes) {
      return _fail(HistoryTransferError.tooLarge);
    }
    _set(HistoryTransferPhase.confirm);
    return null;
  }

  /// Source, step 2 (after the user confirmed): upload, then the key to the
  /// target through the own-device fan-out.
  Future<void> confirm() async {
    final code = _target;
    final archive = _archive;
    if (_phase != HistoryTransferPhase.confirm ||
        code == null ||
        archive == null) {
      return;
    }
    final uploadKey = _uploadKey;
    final folder = MediaService.uploadFolder(uploadKey);
    _set(HistoryTransferPhase.uploading);
    _media.addListener(_onMediaProgress);
    MediaInfo info;
    try {
      final stored = await _media.store.import(
        folder,
        historyArchiveName,
        Stream.value(archive),
        maxBytes: _media.maxBytes,
      );
      final keys = newMediaKey();
      info = await _media.upload(
        uploadKey,
        MediaInfo(
          id: '',
          kind: MediaKind.file,
          name: historyArchiveName,
          mime: _archiveMime,
          size: stored.size,
          sha256: stored.sha256,
          key: keys.key,
          nonce: keys.nonce,
        ),
        folder: folder,
        // Nothing to resume after a restart: a failed transfer starts over
        // from a new code (spec, no resume in v1).
        persist: (_, _) async {},
      );
    } on MediaCancelled {
      await _media.deleteLocal(folder);
      return;
    } catch (_) {
      await _media.deleteLocal(folder);
      if (_target == code) _fail(HistoryTransferError.network);
      return;
    } finally {
      _media.removeListener(_onMediaProgress);
    }
    // The plaintext copy is not needed once the relay has the ciphertext.
    await _media.deleteLocal(info.id);
    if (_target != code) {
      await _deleteRemote(info.id);
      return;
    }
    _uploaded = info;
    _archive = null;
    final source = await newHistoryTransferKeyPair();
    final offer = HistoryTransferOffer(
      transferId: code.transferId,
      targetDeviceId: code.targetDeviceId,
      mediaId: info.id,
      size: info.size,
      sha256: info.sha256,
      sourceEphemeralKey: await historyTransferPublicKey(source),
      wrappedKey: await wrapArchiveKey(
        source: source,
        targetPublicKey: code.targetPublicKey,
        key: info.key,
        nonce: info.nonce,
      ),
    );
    _set(HistoryTransferPhase.waitingForTarget);
    if (!await _sender.send(historyTransferType, offer.encode())) {
      await _deleteRemote(info.id);
      _uploaded = null;
      _fail(HistoryTransferError.network);
    }
  }

  Future<void> _onDone(OwnControlMessage message) async {
    final done = HistoryTransferDone.decode(message.body);
    final uploaded = _uploaded;
    if (done == null ||
        uploaded == null ||
        _role != HistoryTransferRole.source ||
        done.transferId != _transferId ||
        message.senderDeviceId != _target?.targetDeviceId.toLowerCase()) {
      return;
    }
    _uploaded = null;
    await _deleteRemote(uploaded.id);
    _set(HistoryTransferPhase.done);
  }

  // ---------------------------------------------------------------- shared

  /// Cancel on either side: the source withdraws the upload, the target
  /// drops its key and temporary file. Back to idle.
  Future<void> cancel() async {
    _expiry?.cancel();
    _expiry = null;
    _keyPair = null;
    _code = null;
    final download = _download;
    _download = null;
    if (download != null) {
      _media.cancelDownload(download.id);
      await _media.deleteLocal(download.id);
    }
    if (_phase == HistoryTransferPhase.uploading) {
      // MediaService.upload deletes the blob on cancel.
      _media.cancelUpload(_uploadKey);
    }
    final uploaded = _uploaded;
    _uploaded = null;
    if (uploaded != null && _phase != HistoryTransferPhase.done) {
      await _deleteRemote(uploaded.id);
    }
    _target = null;
    _archive = null;
    _chats = 0;
    _transferId = null;
    _importedMessages = 0;
    _role = HistoryTransferRole.none;
    _error = null;
    _set(HistoryTransferPhase.idle);
  }

  Future<void> _deleteRemote(String mediaId) async {
    try {
      await _media.deleteRemote(mediaId);
    } catch (_) {
      // The relay deletes it after the retention anyway.
    }
  }

  HistoryTransferError _fail(HistoryTransferError error) {
    _expiry?.cancel();
    _keyPair = null;
    _error = error;
    _set(HistoryTransferPhase.failed);
    return error;
  }

  void _onMediaProgress() => _notify();

  void _set(HistoryTransferPhase phase) {
    _phase = phase;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _expiry?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
