import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// A non-2xx answer of the operator API. [code] is the machine code from the
/// `{"error", "code"}` body (contract: errors keep the channel endpoints'
/// shape), null when the server sent none.
class AdminApiException implements Exception {
  AdminApiException(this.statusCode, this.code, [this.message]);

  final int statusCode;
  final String? code;
  final String? message;

  @override
  String toString() => 'AdminApiException($statusCode, $code, $message)';
}

/// The network failed before any HTTP status (offline, CORS, DNS).
class AdminNetworkException implements Exception {
  AdminNetworkException(this.cause);
  final Object cause;
  @override
  String toString() => 'AdminNetworkException($cause)';
}

/// lower-case hex SHA-256 of the passphrase: the exact authKey the app sends
/// to `POST /accounts/login` (account_screen.dart), so the same account
/// credentials work here.
String deriveAuthKey(String passphrase) =>
    sha256.convert(utf8.encode(passphrase)).toString();

/// Minimal client for `/admin/*`.
///
/// WHY not calltype_core's ApiClient: that one authenticates as a DEVICE and
/// the server refuses device tokens on /admin (403 operator_token_required).
/// The operator token lives only in this object's memory: never in
/// localStorage, so a stolen browser profile holds nothing reusable.
class AdminApi {
  AdminApi({required String baseUrl, http.Client? client})
    : _base = baseUrl,
      _http = client ?? http.Client();

  final String _base;
  final http.Client _http;
  String? _token;

  /// Called on 401 from any authenticated route; the app turns it into "back
  /// to the login, then back to where you were".
  void Function()? onUnauthorized;

  String get baseUrl => _base;
  bool get hasToken => _token != null;

  void setToken(String? token) => _token = token;

  Uri _uri(String path, [Map<String, String?> query = const {}]) {
    final q = <String, String>{
      for (final e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return Uri.parse('$_base$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<http.Response> _send(Future<http.Response> Function() call, {bool auth = true}) async {
    http.Response r;
    try {
      r = await call();
    } catch (e) {
      throw AdminNetworkException(e);
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return r;
    String? code;
    String? message;
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is Map) {
        code = body['code'] as String?;
        message = body['error'] as String?;
      }
    } catch (_) {
      // Plain 401/403/404 from the framework have no JSON body.
    }
    if (auth && r.statusCode == 401) {
      // The token expired or was revoked. Drop it so nothing else is sent
      // with it, then let the UI ask for a new session.
      _token = null;
      onUnauthorized?.call();
    }
    throw AdminApiException(r.statusCode, code, message);
  }

  Future<dynamic> _getJson(String path, [Map<String, String?> query = const {}]) async {
    final r = await _send(() => _http.get(_uri(path, query), headers: _headers));
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  // 4.1
  Future<AdminSession> createSession({
    required String email,
    required String passphrase,
    String? code,
    String? backupCode,
  }) async {
    final body = {
      'email': email.trim(),
      'authKey': deriveAuthKey(passphrase),
      if (code != null && code.trim().isNotEmpty) 'code': code.replaceAll(' ', ''),
      if (backupCode != null && backupCode.trim().isNotEmpty) 'backupCode': backupCode.trim(),
    };
    final r = await _send(
      () => _http.post(
        _uri('/admin/session'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode(body),
      ),
      // A 401 here is "wrong credentials", not "session expired".
      auth: false,
    );
    return AdminSession.fromJson(
      (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>(),
    );
  }

  // 4.2
  Future<AdminSummary> summary() async =>
      AdminSummary.fromJson((await _getJson('/admin/summary') as Map).cast());

  // 4.3
  Future<ReportPage> reports({
    String status = 'open',
    String? category,
    String? subjectType,
    String? cursor,
    int limit = 50,
  }) async {
    // WHY three cursor names: the contract lets the server implement paging
    // either as `before`/`after` timestamps (open = oldest first, so `after`)
    // or as an opaque `cursor`. Unknown query parameters are ignored by the
    // minimal API, so sending the matching pair works with both.
    final data = await _getJson('/admin/reports', {
      'status': status,
      'category': category,
      'subjectType': subjectType,
      'limit': '$limit',
      'cursor': cursor,
      if (status == 'open') 'after': cursor else 'before': cursor,
    });
    return ReportPage.fromJson((data as Map).cast());
  }

  // 4.4
  Future<CaseDetail> subject(String channelId, {String? postId}) async =>
      CaseDetail.fromJson(
        (await _getJson('/admin/subjects/${Uri.encodeComponent(channelId)}', {
          'postId': postId,
        }) as Map).cast(),
      );

  // 4.5
  Future<Uint8List> attachment(String channelId, String name) async {
    final r = await _send(
      () => _http.get(
        _uri('/admin/channels/${Uri.encodeComponent(channelId)}/attachments/${Uri.encodeComponent(name)}'),
        headers: {if (_token != null) 'Authorization': 'Bearer $_token'},
      ),
    );
    return r.bodyBytes;
  }

  // 4.6
  Future<Decision> decide(DecisionRequest request) async {
    final r = await _send(
      () => _http.post(
        _uri('/admin/decisions'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      ),
    );
    return Decision.fromJson((jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast());
  }

  // 4.7
  Future<List<ChannelSummary>> channels(String q, {int limit = 50}) async =>
      parseList(await _getJson('/admin/channels', {'q': q.trim(), 'limit': '$limit'}), ChannelSummary.fromJson);

  // 4.8
  Future<List<Decision>> decisions({DateTime? before, int limit = 100}) async =>
      parseList(
        await _getJson('/admin/decisions', {
          'before': before?.toUtc().toIso8601String(),
          'limit': '$limit',
          'format': 'json',
        }),
        Decision.fromJson,
      );

  Future<Uint8List> decisionsCsv({DateTime? before, int limit = 100}) async {
    final r = await _send(
      () => _http.get(
        _uri('/admin/decisions', {
          'before': before?.toUtc().toIso8601String(),
          'format': 'csv',
          'limit': '$limit',
        }),
        headers: {..._headers, 'Accept': 'text/csv'},
      ),
    );
    return r.bodyBytes;
  }
}
