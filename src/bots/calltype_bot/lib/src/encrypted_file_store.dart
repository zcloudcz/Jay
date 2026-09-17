import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_core/crypto/backup_crypto.dart';
import 'package:calltype_core/storage/secret_store.dart';

/// [SecretStore] for a headless bot: every secret (identity keys, pre-keys,
/// device credential) lives in ONE JSON file encrypted with AES-256-GCM.
///
/// WHY a file and not the OS keychain: a bot runs in a container with no
/// keychain. The key comes from the environment (`BOT_STORE_KEY`), so a
/// stolen volume alone does not reveal the bot's identity keys.
///
/// The wire format is [BackupCrypto.encrypt]'s (nonce | ciphertext | tag) —
/// reused so there is a single audited AES-GCM framing in the code base.
class EncryptedFileStore extends SecretStore {
  EncryptedFileStore._(this._file, this._key, this._values);

  final File _file;
  final Uint8List _key;
  final Map<String, String> _values;

  /// Serialises writes: two concurrent writers would otherwise share the
  /// same temp file and could rename a half-written one into place.
  Future<void> _tail = Future.value();

  /// Decodes `BOT_STORE_KEY`. Refusing short keys here (rather than padding
  /// or hashing them) keeps a typo from silently producing a weak key.
  static Uint8List parseKey(String? base64Key) {
    if (base64Key == null || base64Key.trim().isEmpty) {
      throw StateError(
        'BOT_STORE_KEY is not set. Generate one with: openssl rand -base64 32',
      );
    }
    final Uint8List key;
    try {
      key = base64Decode(base64Key.trim());
    } on FormatException {
      throw StateError('BOT_STORE_KEY is not valid base64.');
    }
    if (key.length != 32) {
      throw StateError(
        'BOT_STORE_KEY must decode to exactly 32 bytes (got ${key.length}).',
      );
    }
    return key;
  }

  /// Opens (or starts) the store at [path]. A missing file is an empty
  /// store — the file first appears on the first write.
  static Future<EncryptedFileStore> open(String path, Uint8List key) async {
    final file = File(path);
    var values = <String, String>{};
    if (await file.exists()) {
      try {
        final plain = await BackupCrypto.decrypt(key, await file.readAsBytes());
        values = (jsonDecode(utf8.decode(plain)) as Map).cast<String, String>();
      } catch (_) {
        // GCM auth failure = wrong key or a corrupted file. Never fall back
        // to an empty store: that would register a NEW identity and the old
        // one (and every contact's session with it) would be lost silently.
        throw StateError(
          'Cannot decrypt bot store at $path — wrong BOT_STORE_KEY or a '
          'corrupted file. Refusing to start.',
        );
      }
    }
    return EncryptedFileStore._(file, key, values);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) {
    _values[key] = value;
    return _flush();
  }

  @override
  Future<void> delete(String key) {
    _values.remove(key);
    return _flush();
  }

  Future<void> _flush() {
    final result = _tail.then((_) async {
      final bytes = await BackupCrypto.encrypt(
        _key,
        Uint8List.fromList(utf8.encode(jsonEncode(_values))),
      );
      // Atomic replace: a crash mid-write leaves either the old or the new
      // file, never a truncated one (a truncated store = lost identity).
      final temp = File('${_file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(_file.path);
    });
    // Keep the chain alive after a failed write so later writes still run.
    _tail = result.catchError((Object _) {});
    return result;
  }
}
