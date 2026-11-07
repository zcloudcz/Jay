import 'package:calltype_core/media/media_info.dart';

import '../../l10n/app_localizations.dart';

// The format itself lives in calltype_core (shared with the bots); this file
// keeps the localized texts.
export 'package:calltype_core/media/media_info.dart';

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
