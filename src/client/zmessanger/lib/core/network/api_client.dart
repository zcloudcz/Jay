import 'package:dio/dio.dart';

/// REST client for the ZMessanger backend API.
///
/// Wraps [Dio] to provide typed methods for every server endpoint the
/// client needs. Each method documents the endpoint it calls and the
/// shape of its response so callers don't need to guess at JSON keys.
///
/// The base URL is injected via constructor so the app can point at
/// different environments (localhost during dev, staging, production)
/// without rebuilding.
class ApiClient {
  ApiClient({required String baseUrl, Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl));

  final Dio _dio;

  // -- Device registration ---------------------------------------------------

  /// Registers a new anonymous device with the server.
  ///
  /// Uploads the device's public identity key, signed pre-key, and a batch
  /// of one-time pre-keys required for X3DH key agreement. The server
  /// assigns a device UUID and a human-readable handle (ZM-XXXX-XXXX).
  ///
  /// POST /devices
  Future<Map<String, dynamic>> registerDevice({
    required String identityKey,
    required String signedPreKey,
    required List<String> oneTimePreKeys,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/devices',
      data: {
        'identityKey': identityKey,
        'signedPreKey': signedPreKey,
        'oneTimePreKeys': oneTimePreKeys,
      },
    );
    return response.data!;
  }

  // -- Key bundle ------------------------------------------------------------

  /// Fetches the X3DH key bundle for a remote device.
  ///
  /// The bundle contains the identity key, signed pre-key, and one
  /// one-time pre-key (consumed on use). The initiating device uses
  /// this bundle to perform X3DH and establish a Double Ratchet session
  /// without requiring the recipient to be online.
  ///
  /// GET /devices/{deviceId}/key-bundle
  Future<Map<String, dynamic>> getKeyBundle(String deviceId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/devices/$deviceId/key-bundle',
    );
    return response.data!;
  }

  // -- TURN credentials ------------------------------------------------------

  /// Fetches time-limited TURN relay credentials for WebRTC calls.
  ///
  /// TURN is needed when direct peer-to-peer connections fail due to
  /// symmetric NATs or restrictive firewalls. The credentials expire
  /// after [ttlSeconds] to limit abuse.
  ///
  /// GET /turn/credentials?deviceId={deviceId}
  Future<Map<String, dynamic>> getTurnCredentials(String deviceId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/turn/credentials',
      queryParameters: {'deviceId': deviceId},
    );
    return response.data!;
  }

  // -- Account (optional registration) ---------------------------------------

  /// Registers an optional account for cloud backup and multi-device sync.
  ///
  /// The [authKey] is derived client-side from the user's passphrase via
  /// Argon2id — the server only ever sees the derived key, never the raw
  /// passphrase. Registration is optional; the app works fully without it.
  ///
  /// POST /accounts
  Future<Map<String, dynamic>> registerAccount({
    required String email,
    required String authKey,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/accounts',
      data: {'email': email, 'authKey': authKey},
    );
    return response.data!;
  }

  /// Authenticates an existing account.
  ///
  /// Returns an account ID on success. Used when setting up a new device
  /// on an existing account (multi-device) or restoring from backup.
  ///
  /// POST /accounts/login
  Future<Map<String, dynamic>> login({
    required String email,
    required String authKey,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/accounts/login',
      data: {'email': email, 'authKey': authKey},
    );
    return response.data!;
  }
}
