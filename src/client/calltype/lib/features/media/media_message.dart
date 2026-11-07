import 'dart:convert';
import 'dart:typed_data';

import '../../l10n/app_localizations.dart';
import 'media_thumbnail.dart' show jpegDimensions, mediaThumbnailSide;

/// What a media message carries (contract section 3 `kind`). Decides the
/// bubble (player, viewer, plain file) and the notification label only;
/// the bytes are treated the same for every kind.
enum MediaKind {
  image,
  video,
  audio,
  voice,
  file;

  /// Unknown kinds from a newer client fall back to a plain file.
  static MediaKind parse(Object? value) => MediaKind.values.firstWhere(
    (k) => k.name == value,
    orElse: () => MediaKind.file,
  );
}

/// Plaintext chunk size every new upload uses (contract section 1).
const mediaChunkSize = 4 * 1024 * 1024;

/// Accepted plaintext chunk sizes when decoding (contract section 1).
const mediaMinChunkSize = 1024 * 1024;
const mediaMaxChunkSize = 8 * 1024 * 1024;

/// Client plaintext cap on mobile / desktop: 5 GiB minus 1 MiB, the reserve
/// covers the GCM tags so the encrypted size stays under the server's
/// 5 GiB limit (contract section 1).
const mediaMaxBytes = 5 * 1024 * 1024 * 1024 - 1024 * 1024;

/// Web keeps a decrypted file in browser memory, so it has its own cap
/// (contract M13).
const mediaMaxBytesWeb = 512 * 1024 * 1024;

const _maxThumbnailBytes = 24 * 1024;
const _maxCaption = 4096;
const _maxWaveform = 128;

final _guid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _mime = RegExp(r'^[A-Za-z0-9][\w.+-]*/[\w.+-]+$');

/// The inline `Attachment` rules plus what makes a bad file name on some
/// platform: the name becomes a file inside the media folder on every
/// device that downloads it, and it is shown to the user.
bool isValidMediaName(String name) =>
    name.trim().isNotEmpty &&
    name != '.' &&
    name != '..' &&
    name.length <= 255 &&
    // Separators, controls, Windows-reserved characters (`:` would also
    // address an alternate data stream) and bidi controls that can make
    // "evil\u202Efdp.exe" display as "evilexe.pdf".
    !name.contains(_badNameChars) &&
    // Windows drops a trailing dot or space, so the file would not be found.
    !name.endsWith('.') &&
    !name.endsWith(' ') &&
    !_windowsDeviceName.hasMatch(name);

final _badNameChars = RegExp(
  '[/\\\\\x00-\x1f\x7f:<>"|?*\u202a-\u202e\u2066-\u2069]',
);
final _windowsDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)',
  caseSensitive: false,
);

/// Whether opening [name] with the desktop shell could run code instead of
/// showing a document: programs, scripts, installers, shortcuts.
bool isRunnableFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _runnableExtensions.contains(name.substring(dot + 1).toLowerCase());
}

const _runnableExtensions = {
  // Windows
  'exe', 'com', 'scr', 'pif', 'bat', 'cmd', 'msi', 'msp', 'msix', 'appx',
  'appxbundle', 'lnk', 'url', 'hta', 'cpl', 'jar', 'js', 'jse', 'vbs',
  'vbe', 'wsf', 'wsh', 'ps1', 'psm1', 'reg', 'scf', 'inf', 'library-ms',
  'settingcontent-ms', 'application', 'gadget', 'chm', 'dll', 'sys',
  // macOS
  'app', 'command', 'tool', 'pkg', 'mpkg', 'dmg', 'workflow', 'terminal',
  'scpt', 'applescript', 'webloc', 'inetloc', 'fileloc',
  // Linux and Unix
  'desktop', 'sh', 'bash', 'zsh', 'run', 'bin', 'appimage', 'deb', 'rpm',
  'py', 'pl', 'rb',
};

/// The `media` object of a message (contract section 3): where the
/// ciphertext lives on the server plus everything needed to decrypt and
/// verify it. It only ever travels inside the Signal-encrypted payload.
///
/// A local DRAFT (an own message whose upload has not finished) has an
/// empty [id] and no [expiresAt]; it never leaves the device.
class MediaInfo {
  MediaInfo({
    required this.id,
    required this.kind,
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
    required this.key,
    required this.nonce,
    this.chunkSize = mediaChunkSize,
    this.expiresAt,
    this.durationMs,
    this.width,
    this.height,
    this.thumbnail,
    this.waveform,
    this.caption,
  });

  static const version = 1;

  final String id;
  final MediaKind kind;
  final String name;
  final String mime;

  /// Plaintext bytes.
  final int size;
  final Uint8List sha256;
  final Uint8List key;
  final Uint8List nonce;

  /// Plaintext chunk size.
  final int chunkSize;
  final DateTime? expiresAt;
  final int? durationMs;
  final int? width;
  final int? height;
  final Uint8List? thumbnail;
  final Uint8List? waveform;
  final String? caption;

  bool get isDraft => id.isEmpty;

  bool isExpired(DateTime now) {
    final at = expiresAt;
    return at != null && !now.isBefore(at);
  }

  MediaInfo copyWith({
    String? id,
    Uint8List? key,
    Uint8List? nonce,
    DateTime? expiresAt,
  }) => MediaInfo(
    id: id ?? this.id,
    kind: kind,
    name: name,
    mime: mime,
    size: size,
    sha256: sha256,
    key: key ?? this.key,
    nonce: nonce ?? this.nonce,
    chunkSize: chunkSize,
    expiresAt: expiresAt ?? this.expiresAt,
    durationMs: durationMs,
    width: width,
    height: height,
    thumbnail: thumbnail,
    waveform: waveform,
    caption: caption,
  );

  Map<String, Object?> toJson() => {
    'v': version,
    'id': id,
    'kind': kind.name,
    'name': name,
    'mime': mime,
    'size': size,
    'sha256': base64Encode(sha256),
    'key': base64Encode(key),
    'nonce': base64Encode(nonce),
    'chunkSize': chunkSize,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    if (durationMs != null) 'durationMs': durationMs,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (thumbnail != null) 'thumbnail': base64Encode(thumbnail!),
    if (waveform != null) 'waveform': base64Encode(waveform!),
    if (caption != null) 'caption': caption,
  };

  /// Canonical local row body (`messages.body` of a `media` row).
  String encode() => jsonEncode(toJson());

  /// Parses a received `media` object. Returns null for anything invalid or
  /// from a newer format version: the caller then keeps the fallback text,
  /// the message is never dropped (contract section 3). With [draft] an
  /// empty id and a missing expiry are accepted (own unfinished upload).
  static MediaInfo? tryParse(Object? json, {bool draft = false}) {
    if (json is! Map) return null;
    try {
      if (json['v'] != version) return null;
      final id = json['id'];
      if (id is! String || !(_guid.hasMatch(id) || (draft && id.isEmpty))) {
        return null;
      }
      final name = json['name'];
      if (name is! String || !isValidMediaName(name)) return null;
      final mime = json['mime'];
      if (mime is! String || mime.length > 127 || !_mime.hasMatch(mime)) {
        return null;
      }
      final size = json['size'];
      if (size is! int || size < 0 || size > mediaMaxBytes) return null;
      final sha = _bytes(json['sha256'], exact: 32);
      final key = _bytes(json['key'], exact: 32);
      final nonce = _bytes(json['nonce'], exact: 7);
      if (sha == null || key == null || nonce == null) return null;
      final chunkSize = json['chunkSize'];
      if (chunkSize is! int ||
          chunkSize < mediaMinChunkSize ||
          chunkSize > mediaMaxChunkSize) {
        return null;
      }
      DateTime? expiresAt;
      final rawExpiry = json['expiresAt'];
      if (rawExpiry is String) {
        expiresAt = DateTime.tryParse(rawExpiry);
        if (expiresAt == null) return null;
      } else if (rawExpiry != null || !draft) {
        return null;
      }
      final durationMs = _optionalInt(json, 'durationMs', min: 0);
      final width = _optionalInt(json, 'width', min: 1);
      final height = _optionalInt(json, 'height', min: 1);
      if (durationMs == -1 || width == -1 || height == -1) return null;
      Uint8List? thumbnail;
      if (json['thumbnail'] != null) {
        thumbnail = _bytes(json['thumbnail']);
        if (thumbnail == null || thumbnail.length > _maxThumbnailBytes) {
          return null;
        }
        // Only a small JPEG is rendered (see jpegDimensions); anything else
        // loses its preview, not the message.
        final dimensions = jpegDimensions(thumbnail);
        if (dimensions == null ||
            dimensions.width > mediaThumbnailSide ||
            dimensions.height > mediaThumbnailSide) {
          thumbnail = null;
        }
      }
      Uint8List? waveform;
      if (json['waveform'] != null) {
        waveform = _bytes(json['waveform']);
        if (waveform == null ||
            waveform.isEmpty ||
            waveform.length > _maxWaveform) {
          return null;
        }
      }
      final caption = json['caption'];
      if (caption != null &&
          (caption is! String || caption.length > _maxCaption)) {
        return null;
      }
      return MediaInfo(
        // One spelling: the id names the local folder, and case-insensitive
        // file systems would otherwise let two ids share it.
        id: id.toLowerCase(),
        kind: MediaKind.parse(json['kind']),
        name: name,
        mime: mime,
        size: size,
        sha256: sha,
        key: key,
        nonce: nonce,
        chunkSize: chunkSize,
        expiresAt: expiresAt,
        durationMs: durationMs,
        width: width,
        height: height,
        thumbnail: thumbnail,
        waveform: waveform,
        caption: caption as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Decodes a stored row body (see [encode]); drafts included.
  static MediaInfo? tryDecode(String? body) {
    if (body == null) return null;
    try {
      return tryParse(jsonDecode(body), draft: true);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _bytes(Object? value, {int? exact}) {
    if (value is! String) return null;
    try {
      final bytes = base64Decode(value);
      if (exact != null && bytes.length != exact) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// null = absent, -1 = present but invalid.
  static int? _optionalInt(Map json, String key, {required int min}) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int || value < min) return -1;
    return value;
  }
}

/// `m:ss` (or `h:mm:ss`) for a duration in milliseconds.
String formatMediaDuration(int ms) {
  final total = (ms / 1000).round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Human file size with the unit, e.g. `12.4 MB` (decimal units like the
/// platforms' file managers).
String formatMediaSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Kind label for previews, quotes and notifications.
String mediaKindLabel(AppLocalizations l10n, MediaKind kind) => switch (kind) {
  MediaKind.image => l10n.mediaKindImage,
  MediaKind.video => l10n.mediaKindVideo,
  MediaKind.audio => l10n.mediaKindAudio,
  MediaKind.voice => l10n.mediaKindVoice,
  MediaKind.file => l10n.mediaKindFile,
};

/// Short one-line description: caption, else the kind label plus the
/// duration (voice, audio, video) or the file name. Used for reply quotes.
String mediaSummary(AppLocalizations l10n, MediaInfo info) {
  final caption = info.caption?.trim();
  if (caption != null && caption.isNotEmpty) return caption;
  final label = mediaKindLabel(l10n, info.kind);
  final duration = info.durationMs;
  if (info.kind == MediaKind.voice && duration != null) {
    return '$label (${formatMediaDuration(duration)})';
  }
  if (info.kind == MediaKind.file || info.kind == MediaKind.audio) {
    return info.name;
  }
  return duration == null ? label : '$label (${formatMediaDuration(duration)})';
}

/// The `body` an OLD client shows instead of the media (contract M7): what
/// it is and that an update is needed, plus the caption on its own line.
String mediaFallbackBody(AppLocalizations l10n, MediaInfo info) {
  final duration = info.durationMs;
  final what = switch (info.kind) {
    MediaKind.voice when duration != null => l10n.mediaFallbackVoice(
      formatMediaDuration(duration),
    ),
    MediaKind.video => l10n.mediaFallbackVideo(formatMediaSize(info.size)),
    MediaKind.image => l10n.mediaFallbackImage(formatMediaSize(info.size)),
    MediaKind.audio || MediaKind.file || MediaKind.voice =>
      l10n.mediaFallbackFile(info.name, formatMediaSize(info.size)),
  };
  final caption = info.caption?.trim();
  return caption == null || caption.isEmpty ? what : '$what\n$caption';
}

/// Kind for a picked file from its name / MIME type.
MediaKind mediaKindFor(String name, {String? mime}) {
  final type = mime?.split('/').first;
  if (type == 'video') return MediaKind.video;
  if (type == 'audio') return MediaKind.audio;
  if (type == 'image') return MediaKind.image;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (_videoExt.contains(ext)) return MediaKind.video;
  if (_audioExt.contains(ext)) return MediaKind.audio;
  if (_imageExt.contains(ext)) return MediaKind.image;
  return MediaKind.file;
}

const _videoExt = {'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp', 'avi'};
const _audioExt = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac'};
const _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'};

/// [mime] without parameters when it is a valid `type/subtype`, else the
/// type the file name suggests.
String normalizeMediaMime(String? mime, String name) {
  final bare = mime?.split(';').first.trim().toLowerCase();
  if (bare != null && bare.length <= 127 && _mime.hasMatch(bare)) return bare;
  return mediaMimeFor(name);
}

/// MIME type from the file name, used when the picker does not say.
String mediaMimeFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mimes[ext] ?? 'application/octet-stream';
}

const _mimes = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  '3gp': 'video/3gpp',
  'avi': 'video/x-msvideo',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/opus',
  'flac': 'audio/flac',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'bmp': 'image/bmp',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'zip': 'application/zip',
};

/// Reduces amplitude samples (0..1) to [bars] bytes 0..255 for the
/// `waveform` field: the loudest sample of each bucket, so short syllables
/// stay visible.
Uint8List reduceWaveform(List<double> samples, {int bars = 64}) {
  if (samples.isEmpty) return Uint8List(0);
  final out = Uint8List(bars);
  for (var i = 0; i < bars; i++) {
    final start = i * samples.length ~/ bars;
    var end = (i + 1) * samples.length ~/ bars;
    if (end <= start) end = start + 1;
    var peak = 0.0;
    for (var j = start; j < end && j < samples.length; j++) {
      if (samples[j] > peak) peak = samples[j];
    }
    out[i] = (peak.clamp(0.0, 1.0) * 255).round();
  }
  return out;
}
