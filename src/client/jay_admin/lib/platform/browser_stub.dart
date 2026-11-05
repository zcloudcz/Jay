import 'dart:typed_data';

// Non-web fallback; only reached when tests use RealBrowserActions by mistake.
void download(String fileName, Uint8List bytes, String mimeType) =>
    throw UnsupportedError('download is only available in the browser');

void openUrl(Uri url) =>
    throw UnsupportedError('openUrl is only available in the browser');
