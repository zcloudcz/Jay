import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show StringCharacters;

/// Small files travel inside the same authenticated encrypted message as text.
///
/// Wire body (message `type: file`): `{"name", "data"}` plus an optional
/// `"caption"` (photo caption, trimmed, at most [maxCaptionLength]
/// characters, omitted when empty). Readers that predate the caption read
/// only `name` and `data` and ignore it.
class Attachment {
  Attachment({required this.name, required Uint8List bytes, String? caption})
    : bytes = Uint8List.fromList(bytes),
      caption = _normalizeCaption(caption) {
    if (name.trim().isEmpty ||
        name.length > 255 ||
        name.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      throw ArgumentError('Invalid attachment name');
    }
    if (bytes.length > maxBytes) {
      throw ArgumentError('Attachments are limited to 256 KiB');
    }
  }
  static const maxBytes = 256 * 1024;

  /// Longest caption in user-perceived characters; a longer one is cut.
  static const maxCaptionLength = 1024;

  final String name;
  final Uint8List bytes;

  /// Text shown under the photo, or null.
  final String? caption;

  static String? _normalizeCaption(String? caption) {
    final text = caption?.trim();
    if (text == null || text.isEmpty) return null;
    final chars = text.characters;
    return chars.length <= maxCaptionLength
        ? text
        : chars.take(maxCaptionLength).toString().trimRight();
  }

  String encode() => jsonEncode({
    'name': name,
    'data': base64Encode(bytes),
    if (caption != null) 'caption': caption,
  });

  factory Attachment.decode(String body) {
    // The caption may add up to a few KiB of JSON on top of the data.
    if (body.length > maxBytes * 2) {
      throw ArgumentError('Attachment is too large');
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    final caption = data['caption'];
    return Attachment(
      name: data['name'] as String,
      bytes: base64Decode(data['data'] as String),
      // A malformed caption from a newer or broken sender is dropped, the
      // file itself still shows.
      caption: caption is String ? caption : null,
    );
  }
}
