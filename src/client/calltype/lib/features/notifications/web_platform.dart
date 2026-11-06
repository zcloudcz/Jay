// Picks the real browser implementation on the web and an all-absent stub
// everywhere else (VM, tests), so no platform branches leak into callers.
export 'web_platform_stub.dart'
    if (dart.library.js_interop) 'web_platform_web.dart';
