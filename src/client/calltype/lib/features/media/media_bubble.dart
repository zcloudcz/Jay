import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/l10n.dart';
import '../chat/attachment_media.dart';
import 'media_device.dart';
import 'media_device_io.dart'
    if (dart.library.js_interop) 'media_device_web.dart'
    as platform;
import 'media_message.dart';
import 'media_service.dart';

/// What the bubble of a media message shows (contract 4.3).
enum MediaBubbleState {
  /// Own message, upload running (or not finished).
  uploading,
  notDownloaded,
  downloading,
  downloaded,
  expired,
  failed,
  damaged,
  tooLargeForWeb,

  /// Local presence not known yet (first frame).
  checking,
}

MediaBubbleState mediaBubbleState(
  MediaService media,
  MediaInfo info, {
  required String messageId,
  required DateTime now,
}) {
  if (info.isDraft) return MediaBubbleState.uploading;
  final download = media.downloadOf(info.id);
  if (download?.phase == MediaPhase.downloading) {
    return MediaBubbleState.downloading;
  }
  // Before the local check: an own upload's file is already in its final
  // folder while the chunks are still going out.
  if (media.uploadOf(messageId)?.phase == MediaPhase.uploading) {
    return MediaBubbleState.uploading;
  }
  final local = media.isLocal(info);
  if (local == true) return MediaBubbleState.downloaded;
  if (local == null) return MediaBubbleState.checking;
  switch (download?.phase) {
    case MediaPhase.expired:
      return MediaBubbleState.expired;
    case MediaPhase.damaged:
      return MediaBubbleState.damaged;
    case MediaPhase.failed:
      return MediaBubbleState.failed;
    default:
  }
  if (info.isExpired(now)) return MediaBubbleState.expired;
  if (media.isWeb && info.size > mediaMaxBytesWeb) {
    return MediaBubbleState.tooLargeForWeb;
  }
  return MediaBubbleState.notDownloaded;
}

/// The content of a media message bubble. Downloads ONLY on a tap of the
/// Download button (M8); before that it shows what the message itself
/// carries: kind, name, size, thumbnail, duration, waveform, expiry.
class MediaMessageContent extends StatelessWidget {
  const MediaMessageContent({
    super.key,
    required this.messageId,
    required this.info,
    required this.media,
    required this.sending,
    this.onCancelUpload,
    this.now = DateTime.now,
  });

  final String messageId;
  final MediaInfo info;
  final MediaService media;

  /// Own message still in status `sending` (Cancel is offered).
  final bool sending;
  final VoidCallback? onCancelUpload;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: media,
    builder: (context, _) {
      final state = mediaBubbleState(
        media,
        info,
        messageId: messageId,
        now: now(),
      );
      final caption = info.caption;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          key: ValueKey('media-${state.name}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state == MediaBubbleState.downloaded)
              _Downloaded(info: info, media: media)
            else
              _Placeholder(
                info: info,
                state: state,
                media: media,
                messageId: messageId,
                sending: sending,
                onCancelUpload: onCancelUpload,
                now: now(),
              ),
            if (caption != null && caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(caption),
              ),
          ],
        ),
      );
    },
  );
}

IconData _kindIcon(MediaKind kind) => switch (kind) {
  MediaKind.image => Icons.image_outlined,
  MediaKind.video => Icons.movie_outlined,
  MediaKind.audio => Icons.audiotrack_outlined,
  MediaKind.voice => Icons.mic_none_rounded,
  MediaKind.file => Icons.insert_drive_file_outlined,
};

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.info,
    required this.state,
    required this.media,
    required this.messageId,
    required this.sending,
    required this.onCancelUpload,
    required this.now,
  });

  final MediaInfo info;
  final MediaBubbleState state;
  final MediaService media;
  final String messageId;
  final bool sending;
  final VoidCallback? onCancelUpload;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall;
    final duration = info.durationMs;
    final details = [
      formatMediaSize(info.size),
      if (duration != null) formatMediaDuration(duration),
    ].join(' · ');
    final thumbnail = info.thumbnail;
    final waveform = info.waveform;
    final expiresAt = info.expiresAt;
    Widget? status;
    switch (state) {
      case MediaBubbleState.uploading:
        final fraction = media.uploadOf(messageId)?.fraction;
        status = _ProgressRow(
          label: l10n.mediaUploading(((fraction ?? 0) * 100).round()),
          fraction: sending ? fraction : null,
          onCancel: sending && media.isUploading(messageId)
              ? onCancelUpload
              : null,
          showBar: sending,
        );
      case MediaBubbleState.downloading:
        final fraction = media.downloadOf(info.id)?.fraction;
        status = _ProgressRow(
          label: l10n.mediaDownloading(((fraction ?? 0) * 100).round()),
          fraction: fraction,
          onCancel: () => media.cancelDownload(info.id),
          showBar: true,
        );
      case MediaBubbleState.notDownloaded:
        status = FilledButton.tonalIcon(
          key: const ValueKey('media-download'),
          onPressed: () => unawaited(media.download(info)),
          icon: const Icon(Icons.download_rounded),
          label: Text(l10n.mediaDownload),
        );
      case MediaBubbleState.failed || MediaBubbleState.damaged:
        status = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                state == MediaBubbleState.damaged
                    ? l10n.mediaDamaged
                    : l10n.mediaDownloadFailed,
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ),
            TextButton(
              key: const ValueKey('media-retry'),
              onPressed: () => unawaited(media.download(info)),
              child: Text(l10n.mediaRetry),
            ),
          ],
        );
      case MediaBubbleState.expired:
        status = Text(
          l10n.mediaExpired,
          style: small?.copyWith(fontStyle: FontStyle.italic),
        );
      case MediaBubbleState.tooLargeForWeb:
        status = Text(l10n.mediaTooLargeForWeb, style: small);
      case MediaBubbleState.checking || MediaBubbleState.downloaded:
        status = null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (thumbnail != null &&
            (info.kind == MediaKind.image || info.kind == MediaKind.video))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Image.memory(
                    thumbnail,
                    width: 240,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  if (info.kind == MediaKind.video)
                    const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 48,
                      color: Colors.white70,
                    ),
                ],
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_kindIcon(info.kind), size: 28),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (info.kind == MediaKind.voice && waveform != null)
                    SizedBox(
                      width: 160,
                      height: 28,
                      child: WaveformBars(
                        bars: waveform,
                        progress: 0,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Text(
                      info.kind == MediaKind.voice
                          ? mediaKindLabel(l10n, info.kind)
                          : info.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  Text(details, style: small),
                ],
              ),
            ),
          ],
        ),
        if (expiresAt != null &&
            state != MediaBubbleState.expired &&
            state != MediaBubbleState.uploading)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.mediaAvailableUntil(
                DateFormat.MMMd(
                  l10n.localeName,
                ).add_Hm().format(expiresAt.toLocal()),
              ),
              style: small,
            ),
          ),
        if (status != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: status),
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.label,
    required this.fraction,
    required this.onCancel,
    required this.showBar,
  });
  final String label;
  final double? fraction;
  final VoidCallback? onCancel;
  final bool showBar;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (showBar)
        SizedBox(width: 200, child: LinearProgressIndicator(value: fraction)),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          if (onCancel != null)
            TextButton(
              key: const ValueKey('media-cancel'),
              onPressed: onCancel,
              child: Text(context.l10n.commonCancel),
            ),
        ],
      ),
    ],
  );
}

/// The viewer / player of a downloaded media message.
class _Downloaded extends StatelessWidget {
  const _Downloaded({required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  @override
  Widget build(BuildContext context) => switch (info.kind) {
    MediaKind.image => _LocalImage(info: info, media: media),
    MediaKind.video => _VideoTile(info: info, media: media),
    MediaKind.audio ||
    MediaKind.voice => AudioMessagePlayer(info: info, media: media),
    MediaKind.file => _FileTile(info: info, media: media),
  };
}

class _LocalImage extends StatefulWidget {
  const _LocalImage({required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  @override
  State<_LocalImage> createState() => _LocalImageState();
}

class _LocalImageState extends State<_LocalImage> {
  // Kept in state: a new Future per build would reload and flicker.
  late final Future<Uint8List?> _bytes = widget.media.bytesOf(widget.info);

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return _FileTile(info: widget.info, media: widget.media);
        }
        return Semantics(
          button: true,
          label: context.l10n.chatImageSemantics(widget.info.name),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => MediaImageViewer(
                  info: widget.info,
                  bytes: bytes,
                  media: widget.media,
                ),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  bytes,
                  key: const ValueKey('media-image'),
                  fit: BoxFit.contain,
                  cacheWidth: (240 * pixelRatio).round(),
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) =>
                      _FileTile(info: widget.info, media: widget.media),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Full-screen image with pinch zoom and Save.
class MediaImageViewer extends StatelessWidget {
  const MediaImageViewer({
    super.key,
    required this.info,
    required this.bytes,
    required this.media,
  });
  final MediaInfo info;
  final Uint8List bytes;
  final MediaService media;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          icon: const Icon(Icons.download_rounded),
          tooltip: context.l10n.mediaSaveToDevice,
          onPressed: () => saveMediaToDevice(context, info, media),
        ),
      ],
    ),
    body: SafeArea(
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            semanticLabel: context.l10n.chatImageSemantics(info.name),
            errorBuilder: (_, _, _) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      ),
    ),
  );
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  Future<void> _play(BuildContext context) async {
    if (!MediaDevice.instance.inAppVideo) {
      await openMediaWithSystem(context, info, media);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => VideoPlayerScreen(info: info, media: media),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thumbnail = info.thumbnail;
    final duration = info.durationMs;
    return Semantics(
      button: true,
      label: context.l10n.mediaPlay,
      child: GestureDetector(
        key: const ValueKey('media-video-play'),
        onTap: () => _play(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 240,
            constraints: const BoxConstraints(minHeight: 120),
            color: Colors.black,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (thumbnail != null)
                  Image.memory(
                    thumbnail,
                    width: 240,
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                const Icon(
                  Icons.play_circle_fill_rounded,
                  size: 56,
                  color: Colors.white,
                ),
                if (duration != null)
                  PositionedDirectional(
                    end: 8,
                    bottom: 6,
                    child: Text(
                      formatMediaDuration(duration),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// In-app video playback (video_player; Android, iOS, macOS and web).
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final path = await widget.media.pathOf(widget.info);
      final bytes = path == null
          ? await widget.media.bytesOf(widget.info)
          : null;
      final controller = platform.videoControllerFor(
        path: path,
        bytes: bytes,
        mime: widget.info.mime,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.info.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: context.l10n.mediaSaveToDevice,
            onPressed: () =>
                saveMediaToDevice(context, widget.info, widget.media),
          ),
        ],
      ),
      body: Center(
        child: _failed
            ? Text(
                context.l10n.mediaPlaybackFailed,
                style: const TextStyle(color: Colors.white),
              )
            : controller == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    ),
                  ),
                  VideoProgressIndicator(controller, allowScrubbing: true),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => IconButton(
                      color: Colors.white,
                      iconSize: 40,
                      tooltip: value.isPlaying
                          ? context.l10n.mediaPause
                          : context.l10n.mediaPlay,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      onPressed: () => value.isPlaying
                          ? controller.pause()
                          : controller.play(),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_kindIcon(info.kind), size: 28),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(info.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    formatMediaSize(info.size),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 4,
          children: [
            if (!media.isWeb)
              TextButton.icon(
                key: const ValueKey('media-open'),
                onPressed: () => openMediaWithSystem(context, info, media),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(l10n.mediaOpen),
              ),
            TextButton.icon(
              key: const ValueKey('media-save'),
              onPressed: () => saveMediaToDevice(context, info, media),
              icon: const Icon(Icons.save_alt_rounded),
              label: Text(l10n.commonSave),
            ),
          ],
        ),
      ],
    );
  }
}

/// Opens a downloaded file in the system app.
Future<void> openMediaWithSystem(
  BuildContext context,
  MediaInfo info,
  MediaService media,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  var opened = false;
  try {
    final path = await media.pathOf(info);
    if (path != null) opened = await MediaDevice.instance.open(path);
  } catch (_) {
    opened = false;
  }
  if (!opened) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.mediaOpenFailed)));
  }
}

/// "Save to device" (contract M10): photos and videos into the gallery on
/// iOS / Android, anything else through the platform's save route.
Future<void> saveMediaToDevice(
  BuildContext context,
  MediaInfo info,
  MediaService media,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  try {
    final path = await media.pathOf(info);
    final bytes = path == null ? await media.bytesOf(info) : null;
    if (path == null && bytes == null) throw StateError('not downloaded');
    final outcome = await MediaDevice.instance.save(
      name: info.name,
      mime: info.mime,
      toGallery: info.kind == MediaKind.image || info.kind == MediaKind.video,
      path: path,
      bytes: bytes,
      origin: origin,
    );
    if (outcome == SaveOutcome.gallery || outcome == SaveOutcome.file) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.mediaSaved)));
    }
  } on GalleryAccessDenied {
    messenger.showSnackBar(SnackBar(content: Text(l10n.chatImageSaveDenied)));
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.chatAttachmentSaveFailed)),
    );
  }
}

/// Bars of a voice waveform; the part before [progress] (0..1) is drawn in
/// [color], the rest faded.
class WaveformBars extends StatelessWidget {
  const WaveformBars({
    super.key,
    required this.bars,
    required this.progress,
    required this.color,
  });
  final Uint8List bars;
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _WaveformPainter(bars, progress, color),
    size: Size.infinite,
  );
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.bars, this.progress, this.color);
  final Uint8List bars;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final step = size.width / bars.length;
    final width = step * 0.6;
    final played = Paint()..color = color;
    final rest = Paint()..color = color.withAlpha(90);
    for (var i = 0; i < bars.length; i++) {
      final h = (bars[i] / 255 * size.height).clamp(2.0, size.height);
      final x = i * step + (step - width) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, width, h),
          Radius.circular(width / 2),
        ),
        (i + 0.5) / bars.length <= progress ? played : rest,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.bars != bars || old.color != color;
}

/// Inline player for voice messages and audio files: play / pause, seek on
/// the waveform or slider, speed 1x / 1.5x / 2x. The platform player is
/// created on the first Play, never while scrolling a chat.
class AudioMessagePlayer extends StatefulWidget {
  const AudioMessagePlayer({
    super.key,
    required this.info,
    required this.media,
  });
  final MediaInfo info;
  final MediaService media;

  static const speeds = [1.0, 1.5, 2.0];

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  AudioPlayer? _player;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Duration _position = Duration.zero;
  late Duration _duration = Duration(milliseconds: widget.info.durationMs ?? 0);
  bool _playing = false;
  int _speed = 0;

  Future<AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _player = player;
    _subscriptions.addAll([
      player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      }),
      player.onDurationChanged.listen((d) {
        if (mounted && d > Duration.zero) setState(() => _duration = d);
      }),
      player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _playing = s == PlayerState.playing);
      }),
      player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _position = Duration.zero);
      }),
    ]);
    final path = await widget.media.pathOf(widget.info);
    if (path != null) {
      await player.setSource(
        DeviceFileSource(path, mimeType: widget.info.mime),
      );
    } else {
      final bytes = await widget.media.bytesOf(widget.info);
      await player.setSource(BytesSource(bytes!, mimeType: widget.info.mime));
    }
    return player;
  }

  Future<void> _toggle() async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = context.l10n.mediaPlaybackFailed;
    try {
      final player = await _ensurePlayer();
      if (_playing) {
        await player.pause();
      } else {
        await player.setPlaybackRate(AudioMessagePlayer.speeds[_speed]);
        await player.resume();
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  Future<void> _seek(double fraction) async {
    if (_duration == Duration.zero) return;
    final target = _duration * fraction.clamp(0.0, 1.0);
    setState(() => _position = target);
    try {
      await (await _ensurePlayer()).seek(target);
    } catch (_) {}
  }

  Future<void> _cycleSpeed() async {
    setState(() => _speed = (_speed + 1) % AudioMessagePlayer.speeds.length);
    try {
      await _player?.setPlaybackRate(AudioMessagePlayer.speeds[_speed]);
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final waveform = widget.info.waveform;
    final progress = _duration == Duration.zero
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final speed = AudioMessagePlayer.speeds[_speed];
    final shown = _playing || _position > Duration.zero ? _position : _duration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.info.kind == MediaKind.audio)
          Text(widget.info.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('media-audio-toggle'),
              tooltip: _playing ? l10n.mediaPause : l10n.mediaPlay,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              onPressed: _toggle,
            ),
            SizedBox(
              width: 150,
              height: 32,
              child: waveform != null
                  ? LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        onTapDown: (d) =>
                            _seek(d.localPosition.dx / constraints.maxWidth),
                        onHorizontalDragUpdate: (d) =>
                            _seek(d.localPosition.dx / constraints.maxWidth),
                        child: WaveformBars(
                          bars: waveform,
                          progress: progress,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  : Slider(value: progress, onChanged: _seek),
            ),
            TextButton(
              key: const ValueKey('media-audio-speed'),
              onPressed: _cycleSpeed,
              child: Text(
                '${speed == speed.roundToDouble() ? speed.round() : speed}×',
                semanticsLabel: l10n.mediaSpeed,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 12),
          child: Text(
            formatMediaDuration(shown.inMilliseconds),
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}
