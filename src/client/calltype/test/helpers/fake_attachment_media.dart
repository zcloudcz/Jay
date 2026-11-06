import 'dart:typed_data';
import 'dart:ui';

import 'package:calltype/features/chat/attachment_media.dart';
import 'package:image/image.dart' as img;

/// Records what the chat / channel screens ask of the platform pickers,
/// the photo library and the share sheet; set as [AttachmentMedia.instance]
/// in a test and restore the original in tearDown.
class FakeMedia implements AttachmentMedia {
  bool camera = true;
  List<PickedMedia> gallery = const [];
  PickedMedia? cameraImage;
  List<PickedMedia> imageFiles = const [];
  final calls = <String>[];
  final galleryWrites = <String>[];
  final fileWrites = <String>[];
  final shares = <String>[];
  bool denyGallery = false;

  @override
  bool get supportsCamera => camera;
  @override
  Future<List<PickedMedia>> pickGalleryImages() async {
    calls.add('gallery');
    return gallery;
  }

  @override
  Future<PickedMedia?> pickGalleryImage() async {
    calls.add('gallery-one');
    return gallery.firstOrNull;
  }

  @override
  Future<PickedMedia?> pickCameraImage() async {
    calls.add('camera');
    return cameraImage;
  }

  @override
  Future<List<PickedMedia>> pickImageFiles({bool multiple = true}) async {
    calls.add('image-files');
    return imageFiles;
  }

  @override
  Future<PickedMedia?> pickFile() async {
    calls.add('file');
    return null;
  }

  @override
  Future<void> saveToGallery(String name, Uint8List bytes) async {
    if (denyGallery) throw const GalleryAccessDenied();
    galleryWrites.add(name);
  }

  @override
  Future<void> saveFile(String name, Uint8List bytes) async =>
      fileWrites.add(name);

  @override
  Future<void> shareImage(String name, Uint8List bytes, {Rect? origin}) async =>
      shares.add(name);
}

/// A small solid PNG, a stand-in for a picked photo.
Uint8List testPng(int width, int height) {
  final image = img.Image(width: width, height: height)
    ..clear(img.ColorRgb8(30, 120, 200));
  return img.encodePng(image);
}
