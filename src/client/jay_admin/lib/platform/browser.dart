/// Browser side effects behind an interface so widget tests (which run on the
/// Dart VM, where package:web cannot be imported) can record them instead.
library;

import 'dart:typed_data';

import 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart' as impl;

abstract class BrowserActions {
  /// Saves [bytes] as a file download named [fileName].
  void download(String fileName, Uint8List bytes, String mimeType);

  /// Opens [url] in a new tab (rule texts).
  void openUrl(Uri url);
}

class RealBrowserActions implements BrowserActions {
  const RealBrowserActions();

  @override
  void download(String fileName, Uint8List bytes, String mimeType) =>
      impl.download(fileName, bytes, mimeType);

  @override
  void openUrl(Uri url) => impl.openUrl(url);
}
