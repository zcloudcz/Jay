import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'attachment.dart';
import 'attachment_media.dart';
import 'image_compression.dart';

/// Saves [attachment]: an image goes to the photo library on iOS / Android
/// (FilePicker's save dialog would land it in the Files app, where nobody
/// looks for a photo), everything else through the platform save dialog.
Future<void> saveAttachment(BuildContext context, Attachment attachment) async {
  // Captured before the awaits: the bubble or viewer may be gone afterwards.
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final media = AttachmentMedia.instance;
  try {
    if (AttachmentMedia.isMobile && isImageAttachmentName(attachment.name)) {
      await media.saveToGallery(attachment.name, attachment.bytes);
      messenger.showSnackBar(SnackBar(content: Text(l10n.chatImageSaved)));
    } else {
      await media.saveFile(attachment.name, attachment.bytes);
    }
  } on GalleryAccessDenied {
    messenger.showSnackBar(SnackBar(content: Text(l10n.chatImageSaveDenied)));
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.chatAttachmentSaveFailed)),
    );
  }
}

Future<void> _share(BuildContext context, Attachment attachment) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  try {
    await AttachmentMedia.instance.shareImage(
      attachment.name,
      attachment.bytes,
      origin: origin,
    );
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.chatImageShareFailed)));
  }
}

/// Inline preview of an image attachment inside a chat bubble. When the
/// bytes do not decode (wrong extension, truncated file) it shows
/// [fallback], the ordinary download button, so the file stays reachable.
class ImageAttachmentThumbnail extends StatelessWidget {
  const ImageAttachmentThumbnail({
    super.key,
    required this.attachment,
    required this.fallback,
  });

  final Attachment attachment;
  final Widget fallback;

  /// WhatsApp-like bubble width; the height follows the aspect ratio but is
  /// capped so a tall screenshot does not fill the whole chat.
  static const maxWidth = 240.0;
  static const maxHeight = 320.0;

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      button: true,
      label: context.l10n.chatImageSemantics(attachment.name),
      child: GestureDetector(
        onTap: () => openImageViewer(context, attachment),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              attachment.bytes,
              key: const ValueKey('image-attachment-thumbnail'),
              fit: BoxFit.contain,
              // Decode at bubble size, not at 2048 px: a long chat of photos
              // would otherwise keep full-size bitmaps in the image cache.
              cacheWidth: (maxWidth * pixelRatio).round(),
              gaplessPlayback: true,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [attachment] full screen.
Future<void> openImageViewer(BuildContext context, Attachment attachment) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageAttachmentViewer(attachment: attachment),
      ),
    );

/// Full-screen photo with pinch zoom, Save and Share.
class ImageAttachmentViewer extends StatelessWidget {
  const ImageAttachmentViewer({super.key, required this.attachment});
  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          attachment.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: l10n.commonSave,
            onPressed: () => saveAttachment(context, attachment),
          ),
          Builder(
            // Its own context so the iPad share popover anchors at the button.
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: l10n.commonShare,
              onPressed: () => _share(buttonContext, attachment),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: Image.memory(
              attachment.bytes,
              key: const ValueKey('image-attachment-full'),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              semanticLabel: l10n.chatImageSemantics(attachment.name),
              errorBuilder: (context, error, stackTrace) => const Icon(
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
}
