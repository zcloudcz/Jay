import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

void download(String fileName, Uint8List bytes, String mimeType) {
  // An object URL + <a download> keeps the CSV entirely client-side: the
  // export needs the Bearer token, so a plain link to the API cannot work.
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}

void openUrl(Uri url) {
  // noopener: the rules page must not get a handle on the admin window.
  web.window.open(url.toString(), '_blank', 'noopener');
}
