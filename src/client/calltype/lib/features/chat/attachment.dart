import 'dart:convert';
import 'dart:typed_data';

/// Small files travel inside the same authenticated encrypted message as text.
class Attachment {
  Attachment({required this.name, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes) {
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
  final String name;
  final Uint8List bytes;
  String encode() => jsonEncode({'name': name, 'data': base64Encode(bytes)});
  factory Attachment.decode(String body) {
    if (body.length > maxBytes * 2) {
      throw ArgumentError('Attachment is too large');
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    return Attachment(
      name: data['name'] as String,
      bytes: base64Decode(data['data'] as String),
    );
  }
}
