import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'attachment.dart';
import 'attachment_sheet.dart';

/// What the user confirmed on the [PhotoSendPreview]: the photos left after
/// removing some, in order, and the caption (null when empty). The caller
/// puts the caption on the first photo only.
class PhotoSendResult {
  const PhotoSendResult({required this.photos, required this.caption});
  final List<PreparedPhoto> photos;
  final String? caption;
}

/// Opens the review screen for converted [photos] (all with bytes). Returns
/// null when the user cancels or removes every photo.
Future<PhotoSendResult?> showPhotoSendPreview(
  BuildContext context,
  List<PreparedPhoto> photos,
) => Navigator.of(context).push<PhotoSendResult>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => PhotoSendPreview(photos: photos),
  ),
);

/// Full-screen review before photos are sent: the selected photo large, a
/// strip of all of them (tap to select, x to remove), a caption field and
/// the send button. Nothing is sent from here; the result goes back to the
/// chat screen.
class PhotoSendPreview extends StatefulWidget {
  const PhotoSendPreview({super.key, required this.photos});
  final List<PreparedPhoto> photos;

  @override
  State<PhotoSendPreview> createState() => _PhotoSendPreviewState();
}

class _PhotoSendPreviewState extends State<PhotoSendPreview> {
  late final List<PreparedPhoto> _photos = [
    for (final p in widget.photos)
      if (p.bytes != null) p,
  ];
  final _caption = TextEditingController();
  int _selected = 0;

  void _remove(int index) {
    if (_photos.length == 1) {
      // Removing the last photo leaves nothing to send: same as cancel.
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _photos.removeAt(index);
      if (_selected >= _photos.length) _selected = _photos.length - 1;
    });
  }

  void _send() {
    final caption = _caption.text.trim();
    Navigator.of(context).pop(
      PhotoSendResult(
        photos: List.unmodifiable(_photos),
        caption: caption.isEmpty ? null : caption,
      ),
    );
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.chatPhotoPreviewTitle(_photos.length)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: Image.memory(
                  _photos[_selected].bytes!,
                  key: ValueKey('photo-preview-large-$_selected'),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _Thumbnail(
                key: ValueKey('photo-preview-${_photos[i].name}'),
                photo: _photos[i],
                selected: i == _selected,
                removeTooltip: l10n.chatPhotoPreviewRemove,
                onTap: () => setState(() => _selected = i),
                onRemove: () => _remove(i),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: Attachment.maxCaptionLength,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: l10n.chatPhotoCaptionHint,
                        counterText: '',
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    icon: const Icon(Icons.send_rounded),
                    tooltip: l10n.chatInputSend,
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    super.key,
    required this.photo,
    required this.selected,
    required this.removeTooltip,
    required this.onTap,
    required this.onRemove,
  });

  final PreparedPhoto photo;
  final bool selected;
  final String removeTooltip;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: 72,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  photo.bytes!,
                  fit: BoxFit.cover,
                  cacheWidth: (64 * pixelRatio).round(),
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          PositionedDirectional(
            top: 0,
            end: 0,
            child: Material(
              color: colorScheme.surface.withAlpha(220),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Tooltip(
                  message: removeTooltip,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 16),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
