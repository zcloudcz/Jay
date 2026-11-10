import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'provider.dart';

/// Default and ceiling of `LLM_IMAGE_MAX_BYTES` (spec 2026-11-10-bot-media
/// M4): 5 MB is Anthropic's per-image API limit; 20 MB is OpenAI's.
const defaultImageMaxBytes = 5 * 1024 * 1024;
const imageMaxBytesCeiling = 20 * 1024 * 1024;

/// What arrived with a chat message, as the bridge needs it. The Jay glue
/// fills it from a `BotAttachment`; tests fill it directly.
class IncomingFile {
  const IncomingFile({
    required this.name,
    required this.mime,
    required this.size,
    required this.isImage,
    required this.read,
    this.caption,
  });

  final String name;

  /// The sender's declared MIME type (a hint only, see [sniffImageType]).
  final String mime;
  final int size;

  /// The sender marked it as an image (media kind `image` or an image MIME).
  final bool isImage;
  final String? caption;

  /// Downloads and decrypts the file, at most [maxBytes]. Throws
  /// [IncomingFileExpired], [IncomingFileTooLarge] or anything else for a
  /// broken file.
  final Future<Uint8List> Function(int maxBytes) read;
}

class IncomingFileExpired implements Exception {
  const IncomingFileExpired();
}

class IncomingFileTooLarge implements Exception {
  const IncomingFileTooLarge();
}

/// The outcome of [readIncomingImage]: an image for the model, or a text
/// for the user (and no model call).
sealed class ImageIntake {
  const ImageIntake();
}

class AcceptedImage extends ImageIntake {
  const AcceptedImage(this.image);
  final ChatImage image;
}

class RefusedFile extends ImageIntake {
  const RefusedFile(this.reply);
  final String reply;
}

/// Decides whether [file] goes to the model (spec M4/M6). Nothing is
/// downloaded for a file that is not an image or is too large by its
/// declared size; the type comes from the bytes, not the declared MIME.
Future<ImageIntake> readIncomingImage(
  IncomingFile file, {
  int maxBytes = defaultImageMaxBytes,
  void Function(String) log = _noLog,
}) async {
  if (!file.isImage) {
    return RefusedFile(ImageTexts.unsupported(file.name, maxBytes));
  }
  if (file.size > maxBytes) {
    return RefusedFile(ImageTexts.tooLarge(file.name, maxBytes));
  }
  final Uint8List bytes;
  try {
    bytes = await file.read(maxBytes);
  } on IncomingFileExpired {
    return const RefusedFile(ImageTexts.expired);
  } on IncomingFileTooLarge {
    return RefusedFile(ImageTexts.tooLarge(file.name, maxBytes));
  } catch (e) {
    log('Image ${file.name} unreadable: $e');
    return const RefusedFile(ImageTexts.broken);
  }
  final type = sniffImageType(bytes);
  if (type == null) {
    return RefusedFile(ImageTexts.unsupported(file.name, maxBytes));
  }
  return AcceptedImage(
    ChatImage(bytes: bytes, mediaType: type, name: file.name),
  );
}

void _noLog(String _) {}

/// The user-facing texts about files, in one place.
abstract final class ImageTexts {
  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  static String supported(int maxBytes) =>
      'I can read text and images (JPEG, PNG, GIF, WebP up to '
      '${_mb(maxBytes)}).';

  static String unsupported(String name, int maxBytes) =>
      'Sorry, I cannot open "$name". ${supported(maxBytes)}';

  static String tooLarge(String name, int maxBytes) =>
      'Sorry, "$name" is too large for me. ${supported(maxBytes)}';

  static const expired =
      'Sorry, that file is no longer available on the server. Please send '
      'it again.';

  static const broken =
      'Sorry, I could not open that image. Please send it again.';

  /// Appended to the system prompt when image generation is on (M8).
  static const generationHint =
      'You can create pictures: when the user asks for an image, put a line '
      '[[image: <a detailed description in English>]] into your answer '
      '(at most 2 per answer) and the picture is sent to the chat. Do not '
      'use it otherwise.';

  static String generationFailed(String detail) =>
      '(I could not create the image: $detail)';
}

/// History placeholder of a received image (M7): the bytes are never kept.
String imagePlaceholder(String name) => '[image: $name]';

/// History placeholder of a generated image (M8).
String generatedPlaceholder(String prompt) => '[image sent: $prompt]';

/// At most this many `[[image: ...]]` tags of one answer are generated.
const maxImagesPerAnswer = 2;

final _imageTag = RegExp(r'\[\[image:\s*([\s\S]*?)\s*\]\]');

/// Takes the `[[image: prompt]]` tags out of [answer]: the text without
/// them and the prompts (all of them; the caller generates the first
/// [maxImagesPerAnswer]).
({String text, List<String> prompts}) extractImageTags(String answer) {
  final prompts = <String>[
    for (final m in _imageTag.allMatches(answer))
      if (m.group(1)!.trim().isNotEmpty) m.group(1)!.trim(),
  ];
  final text = answer
      .replaceAll(_imageTag, '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return (text: text, prompts: prompts);
}

/// Creates an image from a text prompt.
abstract class ImageGenerator {
  String get label;

  /// PNG (or whatever the API returns) bytes; errors are [LlmException]s.
  Future<Uint8List> generate(String prompt);

  Future<void> close();
}

/// OpenAI Images API (`POST {base}/images/generations`), opt-in through
/// `LLM_IMAGE_MODEL` (spec M8).
///
/// Wire shape per platform.openai.com/docs/api-reference/images (checked
/// 2026-11-10): body `model`, `prompt`, `n`, `size`; the answer is
/// `data[0].b64_json`. GPT image models always return base64 and reject
/// `response_format`; DALL-E models need `response_format: b64_json`.
class OpenAiImageGenerator extends HttpJsonClient implements ImageGenerator {
  OpenAiImageGenerator({
    required this.model,
    this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.size = '1024x1024',
    this.timeout = const Duration(seconds: 180),
    super.client,
  });

  final String model;
  final String? apiKey;
  final String baseUrl;
  final String size;
  final Duration timeout;

  @override
  String get label => 'OpenAI images $model';

  bool get _azure => Uri.parse(baseUrl).host.endsWith('.azure.com');

  /// The request body, public for tests.
  Map<String, Object?> requestBody(String prompt) => {
    'model': model,
    'prompt': prompt,
    'n': 1,
    'size': size,
    if (model.startsWith('dall-e')) 'response_format': 'b64_json',
  };

  @override
  Future<Uint8List> generate(String prompt) async {
    Future<Uint8List> run() async {
      final key = apiKey;
      final response =
          await postJson(Uri.parse('$baseUrl/images/generations'), {
            if (key != null) 'authorization': 'Bearer $key',
            if (key != null && _azure) 'api-key': key,
          }, requestBody(prompt));
      final json = await HttpJsonClient.readJson(response);
      final data = json is Map ? json['data'] : null;
      final first = data is List && data.isNotEmpty ? data.first : null;
      final b64 = first is Map ? first['b64_json'] : null;
      if (b64 is! String || b64.isEmpty) {
        throw const LlmException('the image API returned no image data');
      }
      try {
        return base64Decode(b64);
      } on FormatException {
        throw const LlmException('the image API returned invalid base64');
      }
    }

    return run().timeout(
      timeout,
      onTimeout: () => throw const LlmException('image generation timed out'),
    );
  }
}

/// Writes [bytes] to a fresh file in [dir] (created owner-only) and returns
/// its path; the caller deletes it after sending.
Future<String> writeTempImage(String dir, Uint8List bytes) async {
  final d = Directory(dir);
  if (!await d.exists()) {
    await d.create(recursive: true);
    if (!Platform.isWindows) await Process.run('chmod', ['700', dir]);
  }
  final ext = switch (sniffImageType(bytes)) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  final path =
      '$dir${Platform.pathSeparator}image-'
      '${DateTime.now().microsecondsSinceEpoch}.$ext';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}
