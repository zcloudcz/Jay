import 'package:dio/dio.dart';

import '../storage/secret_store.dart';

/// Obtains and caches the JWT the device uses for every API call and the
/// SignalR connection.
///
/// The credential flow (see AuthEndpoints.cs on the server):
///   1. `POST /devices` returned a one-time `deviceSecret` at registration —
///      it lives in SecureStorage and never leaves the device again except
///      to be exchanged for tokens.
///   2. `POST /auth/token { deviceId, deviceSecret }` → `{ token, expiresAt }`.
///   3. The JWT (24h lifetime) is attached as a Bearer header by the
///      ApiClient interceptor and as `access_token` by the SignalR client.
///
/// Uses its OWN bare Dio instance (no auth interceptor) — the token endpoint
/// must be called without a Bearer header, and routing it through ApiClient
/// would recurse (interceptor asks for a token to fetch a token).
///
/// Returns null instead of throwing when the device has not registered yet —
/// callers (registration itself, health checks) must work unauthenticated.
class AuthService {
  AuthService({
    required SecretStore secureStorage,
    required String baseUrl,
    Dio? dio,
  })  : _secureStorage = secureStorage,
        _dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl));

  final SecretStore _secureStorage;
  final Dio _dio;

  /// Refresh this long before actual expiry so an outgoing request never
  /// carries a token that dies mid-flight.
  static const _expiryMargin = Duration(minutes: 5);

  String? _cachedToken;
  DateTime? _expiresAt;

  /// De-duplicates concurrent refreshes: when several requests hit a missing
  /// or expired token at once, only one token exchange goes to the server.
  Future<String?>? _inflight;

  /// Returns a valid JWT, fetching a fresh one when the cache is empty or
  /// near expiry. Returns null when the device is not registered yet.
  ///
  /// [forceRefresh] bypasses the cache — used by the 401-retry interceptor
  /// when the server rejected a token we believed was still valid (e.g.
  /// clock skew, server-side secret rotation).
  Future<String?> getToken({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedToken != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!.subtract(_expiryMargin))) {
      return _cachedToken;
    }

    // Join an in-flight exchange instead of starting a parallel one.
    final pending = _inflight;
    if (pending != null) return pending;

    final future = _fetchToken();
    _inflight = future;
    try {
      return await future;
    } finally {
      _inflight = null;
    }
  }

  /// Drops the cached token. Call on logout / device reset.
  void clearToken() {
    _cachedToken = null;
    _expiresAt = null;
  }

  Future<String?> _fetchToken() async {
    final deviceId = await _secureStorage.getDeviceId();
    final deviceSecret = await _secureStorage.getDeviceSecret();

    // Not registered yet — unauthenticated mode (registration + health
    // endpoints work without a token).
    if (deviceId == null || deviceSecret == null) return null;

    final response = await _dio.post<Map<String, dynamic>>(
      '/auth/token',
      data: {'deviceId': deviceId, 'deviceSecret': deviceSecret},
    );

    final token = response.data!['token'] as String;
    _cachedToken = token;
    _expiresAt = DateTime.parse(response.data!['expiresAt'] as String);
    return token;
  }
}
