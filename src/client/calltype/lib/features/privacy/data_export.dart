import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/user_safety_api.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// Hands the export file to the user; false = cancelled. A variable so
/// widget tests record the file instead of reaching a platform plugin.
typedef ExportSaver = Future<bool> Function(String name, Uint8List bytes);

/// Share sheet on iOS and Android (their way to "save to Files" or send it
/// on), the browser download on web and a save dialog on desktop (spec D13).
@visibleForTesting
ExportSaver exportSaver = (name, bytes) async {
  const mime = 'application/json';
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  if (mobile) {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: mime)],
        fileNameOverrides: [name],
      ),
    );
    return result.status != ShareResultStatus.dismissed;
  }
  final target = await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    mimeType: mime,
  );
  // The web download has no target to report back; it started.
  return kIsWeb || target != null;
};

/// "Export my data" (spec A4 / D13): the account export for a registered
/// device, the device export for an anonymous one. The JSON is saved as the
/// server sent it, pretty-printed so a person can read it.
Future<bool> exportMyData({
  required ApiClient api,
  required String deviceId,
  String? accountId,
  DateTime? now,
}) async {
  final raw = accountId != null
      ? await api.exportAccountJson(accountId)
      : await api.exportDeviceJson(deviceId);
  String pretty;
  try {
    pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    pretty = raw;
  }
  final date = (now ?? DateTime.now()).toUtc().toIso8601String().substring(
    0,
    10,
  );
  return exportSaver(
    'jay-data-export-$date.json',
    Uint8List.fromList(utf8.encode(pretty)),
  );
}
