import 'dart:convert';
import 'dart:typed_data';

/// What a `media` message carries (M2 §4.6).
enum MediaKind { image, video, voice, file }

/// Body of a `media` message: a reference to an encrypted blob on the
/// server plus everything needed to decrypt, verify and preview it.
///
/// The message body is this object as a JSON STRING (like `file` and
/// `call-event`), because the inbox and the archiver require `body is
/// String`. Shared by the app and `jay_archiver` so "well-formed" means the
/// same thing on every receiver.
///
/// Validation is strict on purpose: the body comes from another device and
/// feeds a download (size, blob id), a decryption (key) and image decoders
/// (thumbnail). Unknown keys are IGNORED (forward compatibility — a newer
/// sender may add fields an older receiver does not know).
class MediaRef {
  MediaRef({
    required this.kind,
    required this.blobId,
    required Uint8List key,
    required this.sha256,
    required this.size,
    required this.mime,
    this.name,
    this.width,
    this.height,
    this.durationMs,
    Uint8List? thumbnail,
    Uint8List? waveform,
    this.caption,
    this.exp,
  }) : key = Uint8List.fromList(key),
       thumbnail = thumbnail == null ? null : Uint8List.fromList(thumbnail),
       waveform = waveform == null ? null : Uint8List.fromList(waveform) {
    final error = _validate();
    if (error != null) throw ArgumentError(error);
  }

  /// Wire format version. A receiver rejects anything else, because a new
  /// version may change the cipher construction (the blob has no header).
  static const version = 1;

  // Limits (M2 §4.6). Kept public so senders can check BEFORE uploading.
  static const maxBodyChars = 32768;
  static const maxSize = 104857600; // 100 MiB
  static const keyBytes = 32;
  static const maxMimeChars = 127;
  static const maxNameChars = 255;
  static const maxDimension = 16384;
  static const maxDurationMs = 86400000; // 24 h
  static const maxThumbnailBytes = 16384;
  static const maxWaveformBytes = 256;
  static const maxCaptionChars = 4096;

  /// Plaintext segment size of the blob cipher (M2 "Šifrovací formát"):
  /// every segment carries its own 16-byte GCM tag.
  static const segmentBytes = 65536;
  static const tagBytes = 16;

  final MediaKind kind;

  /// Server blob id (UUID) — `GET /attachments/{blobId}`.
  final String blobId;

  /// AES-256-GCM key, 32 bytes, fresh for every upload.
  final Uint8List key;

  /// Lowercase hex SHA-256 of the PLAINTEXT, verified after decryption.
  final String sha256;

  /// Plaintext size in bytes.
  final int size;
  final String mime;
  final String? name;
  final int? width;
  final int? height;
  final int? durationMs;

  /// Inline JPEG preview.
  final Uint8List? thumbnail;

  /// Voice message amplitudes, 0..255 per sample.
  final Uint8List? waveform;
  final String? caption;

  /// When the server deletes the blob. Informational only — the server is
  /// the authority; a receiver must not trust it for security decisions.
  final DateTime? exp;

  /// Size of the encrypted blob: one GCM tag per 64 KiB segment, and an
  /// empty file is still one (empty, tagged) segment.
  int get encryptedSize {
    final segments = size == 0 ? 1 : (size + segmentBytes - 1) ~/ segmentBytes;
    return size + tagBytes * segments;
  }

  String get keyBase64 => base64Encode(key);

  Map<String, Object?> toJson() => {
    'v': version,
    'kind': kind.name,
    'blobId': blobId,
    'key': base64Encode(key),
    'sha256': sha256,
    'size': size,
    'mime': mime,
    'name': ?name,
    'width': ?width,
    'height': ?height,
    'durationMs': ?durationMs,
    if (thumbnail != null) 'thumbnail': base64Encode(thumbnail!),
    if (waveform != null) 'waveform': base64Encode(waveform!),
    'caption': ?caption,
    if (exp != null) 'exp': exp!.toUtc().toIso8601String(),
  };

  /// The `body` string of a `media` message.
  String encode() => jsonEncode(toJson());

  /// Parses and validates a `media` message body. Throws [FormatException]
  /// on anything malformed — never returns a partially valid reference.
  static MediaRef decode(String body) {
    if (body.length > maxBodyChars) {
      throw const FormatException('media body too long');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const FormatException('media body is not JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('media body must be a JSON object');
    }
    return MediaRef.fromJson(decoded);
  }

  /// Validating counterpart of [toJson] (e.g. for a MediaRef nested in a
  /// `profile` message). Throws [FormatException].
  factory MediaRef.fromJson(Map<String, dynamic> json) {
    if (json['v'] != version) {
      throw const FormatException('unsupported media version');
    }
    final kind = MediaKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (kind == null) throw const FormatException('invalid media kind');
    try {
      return MediaRef(
        kind: kind,
        blobId: _string(json, 'blobId')!,
        key: _bytes(json, 'key')!,
        sha256: _string(json, 'sha256')!,
        size: _int(json, 'size')!,
        mime: _string(json, 'mime')!,
        name: _string(json, 'name', optional: true),
        width: _int(json, 'width', optional: true),
        height: _int(json, 'height', optional: true),
        durationMs: _int(json, 'durationMs', optional: true),
        thumbnail: _bytes(json, 'thumbnail', optional: true),
        waveform: _bytes(json, 'waveform', optional: true),
        caption: _string(json, 'caption', optional: true),
        exp: _date(json, 'exp'),
      );
    } on ArgumentError catch (e) {
      // The constructor reports rule violations as ArgumentError (a sender
      // bug); for received data the contract is FormatException.
      throw FormatException('invalid media: ${e.message}');
    }
  }

  MediaRef copyWith({
    MediaKind? kind,
    String? blobId,
    Uint8List? key,
    String? sha256,
    int? size,
    String? mime,
    String? name,
    int? width,
    int? height,
    int? durationMs,
    Uint8List? thumbnail,
    Uint8List? waveform,
    String? caption,
    DateTime? exp,
  }) => MediaRef(
    kind: kind ?? this.kind,
    blobId: blobId ?? this.blobId,
    key: key ?? this.key,
    sha256: sha256 ?? this.sha256,
    size: size ?? this.size,
    mime: mime ?? this.mime,
    name: name ?? this.name,
    width: width ?? this.width,
    height: height ?? this.height,
    durationMs: durationMs ?? this.durationMs,
    thumbnail: thumbnail ?? this.thumbnail,
    waveform: waveform ?? this.waveform,
    caption: caption ?? this.caption,
    exp: exp ?? this.exp,
  );

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final _mime = RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$');
  // Same rule as the inline `file` Attachment: a name must never be usable
  // as a path (no separators) nor smuggle control characters into the UI.
  static final _badName = RegExp(r'[/\\\x00-\x1f]');

  String? _validate() {
    if (!_uuid.hasMatch(blobId)) return 'blobId is not a UUID';
    if (key.length != keyBytes) return 'key must be $keyBytes bytes';
    if (!_sha256.hasMatch(sha256)) return 'sha256 must be 64 lowercase hex';
    if (size < 0 || size > maxSize) return 'size out of range';
    if (mime.length > maxMimeChars || !_mime.hasMatch(mime)) {
      return 'invalid mime';
    }
    final name = this.name;
    if (name != null &&
        (name.trim().isEmpty ||
            name.length > maxNameChars ||
            _badName.hasMatch(name))) {
      return 'invalid name';
    }
    for (final d in [width, height]) {
      if (d != null && (d < 1 || d > maxDimension)) return 'invalid dimension';
    }
    final durationMs = this.durationMs;
    if (durationMs != null && (durationMs < 0 || durationMs > maxDurationMs)) {
      return 'invalid duration';
    }
    final thumbnail = this.thumbnail;
    if (thumbnail != null &&
        (thumbnail.length > maxThumbnailBytes ||
            thumbnail.length < 2 ||
            thumbnail[0] != 0xFF ||
            thumbnail[1] != 0xD8)) {
      // JPEG only: the preview is decoded before the user asked for it, so
      // the decoder attack surface is kept to one format.
      return 'thumbnail must be a JPEG of at most $maxThumbnailBytes bytes';
    }
    if ((waveform?.length ?? 0) > maxWaveformBytes) return 'waveform too long';
    if ((caption?.length ?? 0) > maxCaptionChars) return 'caption too long';
    return null;
  }

  static String? _string(
    Map<String, dynamic> json,
    String field, {
    bool optional = false,
  }) {
    final value = json[field];
    if (value == null && optional) return null;
    if (value is! String) throw FormatException('$field must be a string');
    return value;
  }

  static int? _int(
    Map<String, dynamic> json,
    String field, {
    bool optional = false,
  }) {
    final value = json[field];
    if (value == null && optional) return null;
    // `is int` also rejects 1.5 and "1": numbers must be exact integers.
    if (value is! int) throw FormatException('$field must be an integer');
    return value;
  }

  static Uint8List? _bytes(
    Map<String, dynamic> json,
    String field, {
    bool optional = false,
  }) {
    final value = _string(json, field, optional: optional);
    if (value == null) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      throw FormatException('$field is not base64');
    }
  }

  static DateTime? _date(Map<String, dynamic> json, String field) {
    final value = _string(json, field, optional: true);
    if (value == null) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw FormatException('$field is not ISO-8601');
    return parsed.toUtc();
  }
}
