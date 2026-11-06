import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

/// A file chosen by the user. Length and bytes are separate so a huge file
/// from the document picker can be rejected before it is read into memory.
class PickedMedia {
  PickedMedia({
    required this.name,
    required Future<int> Function() length,
    required Future<Uint8List> Function() read,
  }) : _length = length,
       _read = read;

  PickedMedia.bytes(this.name, Uint8List bytes)
    : _length = (() async => bytes.length),
      _read = (() async => bytes);

  final String name;
  final Future<int> Function() _length;
  final Future<Uint8List> Function() _read;
  Future<int> length() => _length();
  Future<Uint8List> readAsBytes() => _read();
}

/// Thrown by [AttachmentMedia.saveToGallery] when the user refused the
/// photo library permission, so the UI can point to Settings instead of a
/// generic failure.
class GalleryAccessDenied implements Exception {
  const GalleryAccessDenied();
}

/// Everything the chat and channel screens need from platform pickers,
/// the photo library and the share sheet, behind one seam so widget tests
/// can run without platform channels (same idea as PushMessagingClient).
abstract class AttachmentMedia {
  /// Replaced in tests; the app always uses the plugin implementation.
  static AttachmentMedia instance = PluginAttachmentMedia();

  /// iOS and Android: photos come from the system photo picker and go back
  /// into the photo library. Elsewhere (web, desktop) a file dialog is the
  /// native way to choose and save an image.
  static bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Longest side image_picker is asked for. The real limit is in bytes
  /// (see image_compression.dart); this only keeps the native picker from
  /// handing a 48 MP original to the pure-Dart encoder.
  static const pickerMaxSide = 2048.0;

  /// Native JPEG quality for image_picker's own re-encode (HEIC becomes
  /// JPEG there on iOS). The Dart encoder then picks the final quality.
  static const pickerQuality = 90;

  /// More than this per pick would queue too many encrypted sends at once.
  static const galleryPickLimit = 10;

  bool get supportsCamera;
  Future<List<PickedMedia>> pickGalleryImages();
  Future<PickedMedia?> pickGalleryImage();
  Future<PickedMedia?> pickCameraImage();

  /// Web / desktop: file dialog filtered to images.
  Future<List<PickedMedia>> pickImageFiles({bool multiple = true});
  Future<PickedMedia?> pickFile();
  Future<void> saveToGallery(String name, Uint8List bytes);
  Future<void> saveFile(String name, Uint8List bytes);
  Future<void> shareImage(String name, Uint8List bytes, {Rect? origin});
}

/// Real implementation on image_picker, file_picker, gal and share_plus.
class PluginAttachmentMedia implements AttachmentMedia {
  final _picker = ImagePicker();

  PickedMedia _fromXFile(XFile file) =>
      PickedMedia(name: file.name, length: file.length, read: file.readAsBytes);

  PickedMedia _fromPlatformFile(PlatformFile file) =>
      PickedMedia(name: file.name, length: file.length, read: file.readAsBytes);

  @override
  bool get supportsCamera {
    try {
      return _picker.supportsImageSource(ImageSource.camera);
    } catch (_) {
      return false;
    }
  }

  // requestFullMetadata: false lets iOS use PHPicker without asking for
  // photo library access (the picker runs out of process and only hands
  // over what the user picked); the metadata would be stripped anyway.
  @override
  Future<List<PickedMedia>> pickGalleryImages() async {
    final files = await _picker.pickMultiImage(
      maxWidth: AttachmentMedia.pickerMaxSide,
      maxHeight: AttachmentMedia.pickerMaxSide,
      imageQuality: AttachmentMedia.pickerQuality,
      limit: AttachmentMedia.galleryPickLimit,
      requestFullMetadata: false,
    );
    return files.map(_fromXFile).toList();
  }

  @override
  Future<PickedMedia?> pickGalleryImage() => _pickOne(ImageSource.gallery);

  @override
  Future<PickedMedia?> pickCameraImage() => _pickOne(ImageSource.camera);

  Future<PickedMedia?> _pickOne(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      maxWidth: AttachmentMedia.pickerMaxSide,
      maxHeight: AttachmentMedia.pickerMaxSide,
      imageQuality: AttachmentMedia.pickerQuality,
      requestFullMetadata: false,
    );
    return file == null ? null : _fromXFile(file);
  }

  @override
  Future<List<PickedMedia>> pickImageFiles({bool multiple = true}) async {
    if (!multiple) {
      final file = await FilePicker.pickFile(type: FileType.image);
      return file == null ? const [] : [_fromPlatformFile(file)];
    }
    final files = await FilePicker.pickFiles(type: FileType.image);
    return files.map(_fromPlatformFile).toList();
  }

  @override
  Future<PickedMedia?> pickFile() async {
    final file = await FilePicker.pickFile();
    return file == null ? null : _fromPlatformFile(file);
  }

  @override
  Future<void> saveToGallery(String name, Uint8List bytes) async {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw const GalleryAccessDenied();
    }
    // gal wants the name without extension; it derives the type itself.
    final dot = name.lastIndexOf('.');
    await Gal.putImageBytes(
      bytes,
      name: dot > 0 ? name.substring(0, dot) : name,
    );
  }

  @override
  Future<void> saveFile(String name, Uint8List bytes) async {
    await FilePicker.saveFile(fileName: name, bytes: bytes);
  }

  @override
  Future<void> shareImage(String name, Uint8List bytes, {Rect? origin}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: _mimeOf(name))],
        fileNameOverrides: [name],
        // iPad presents the share sheet as a popover and needs an anchor.
        sharePositionOrigin: origin,
      ),
    );
  }

  static String _mimeOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }
}
