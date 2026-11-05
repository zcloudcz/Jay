/// Build-time configuration of the operator web.
///
/// The deploy workflow passes `--dart-define=CALLTYPE_API_BASE_URL=<https url>`
/// (the repository variable of the same name). The app reads the key
/// `API_BASE_URL` with the default `http://localhost:8080`; we accept that key
/// as a fallback so a local `flutter run` behaves exactly like the app's.
library;

const String _primary = String.fromEnvironment('CALLTYPE_API_BASE_URL');
const String _appKey = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

/// The API base URL compiled into this build, without a trailing slash.
String get configuredApiBaseUrl => normalizeBaseUrl(
  _primary.isNotEmpty ? _primary : _appKey,
);

String normalizeBaseUrl(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

/// Returns null when [url] is usable, else a developer-facing reason.
///
/// WHY at runtime too: deploy.yml already refuses a local or non-HTTPS URL,
/// but this page sends a passphrase-derived auth key and a TOTP code. A
/// hand-made build pointing at plain HTTP on a public host must not even
/// show the login form. Loopback HTTP stays allowed for local development
/// against docker compose.
String? validateApiBaseUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'API base URL "$url" is not an absolute URL.';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' && _isLoopback(uri.host)) return null;
  return 'API base URL "$url" must use HTTPS (plain HTTP only for localhost).';
}

bool _isLoopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';
