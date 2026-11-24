import 'package:dio/dio.dart';

import 'api_client.dart';

// Block and report a user, account deletion and data export (spec
// docs/superpowers/specs/2026-11-14-go-live.md, server rows S2-S11).
// Extensions like backup_api.dart: they only need the authenticated
// transport, and keeping them out of ApiClient leaves the committed mocks
// of the app untouched.

/// One entry of `GET /blocks`: the blocked IDENTITY (primary device id).
class BlockedUser {
  const BlockedUser({
    required this.deviceId,
    required this.userHandle,
    this.displayName,
    this.isBot = false,
    this.createdAt,
  });

  final String deviceId;
  final String userHandle;
  final String? displayName;
  final bool isBot;
  final DateTime? createdAt;

  /// Never throws: a row without an id is dropped by [parseBlockedUsers].
  static BlockedUser? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['deviceId'];
    if (id is! String || id.isEmpty) return null;
    final handle = json['userHandle'];
    final created = json['createdAt'];
    return BlockedUser(
      deviceId: id.toLowerCase(),
      userHandle: handle is String ? handle : '',
      displayName: json['displayName'] is String
          ? json['displayName'] as String
          : null,
      isBot: json['isBot'] == true,
      createdAt: created is String ? DateTime.tryParse(created) : null,
    );
  }
}

/// `{"blocks":[...]}` -> entries; anything malformed is skipped.
List<BlockedUser> parseBlockedUsers(Object? data) {
  final list = data is Map ? data['blocks'] : null;
  if (list is! List) return const [];
  return [for (final row in list) ?BlockedUser.tryParse(row)];
}

/// One message attached to a user report (the reporter's own decrypted
/// copy; the server cannot read E2E content, spec D7).
class ReportEvidence {
  const ReportEvidence({required this.text, this.messageId, this.sentAt});

  final String text;
  final String? messageId;
  final DateTime? sentAt;

  /// Server limit per text (S7).
  static const maxText = 4000;

  /// Server limit per report (S7).
  static const maxMessages = 20;

  Map<String, dynamic> toJson() => {
    'messageId': ?messageId,
    'sentAt': ?sentAt?.toUtc().toIso8601String(),
    // Trimmed to the server's limit instead of failing the whole report.
    'text': text.length > maxText ? text.substring(0, maxText) : text,
  };
}

/// `POST /users/{id}/report` body. Empty texts are left out (the server
/// rejects them) and at most [ReportEvidence.maxMessages] are sent.
Map<String, dynamic> userReportBody({
  required String reason,
  String category = 'terms',
  String? contactEmail,
  bool goodFaith = false,
  String? groupId,
  List<ReportEvidence> messages = const [],
}) => {
  'category': category,
  'reason': reason,
  'contactEmail': ?contactEmail,
  'goodFaith': goodFaith,
  'groupId': ?groupId,
  'messages': [
    for (final m
        in messages
            .where((m) => m.text.trim().isNotEmpty)
            .take(ReportEvidence.maxMessages))
      m.toJson(),
  ],
};

/// Server error code of a Dio failure (`{error, code}` bodies), or null.
String? apiErrorCode(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  return data is Map && data['code'] is String ? data['code'] as String : null;
}

extension UserSafetyApi on ApiClient {
  /// GET /blocks: the caller identity's block list, newest first.
  Future<List<BlockedUser>> getBlockedUsers() async {
    final response = await transport.get<dynamic>('/blocks');
    return parseBlockedUsers(response.data);
  }

  /// PUT /blocks/{deviceId}: blocks the identity of [deviceId] (idempotent).
  Future<void> blockUser(String deviceId) =>
      transport.put<void>('/blocks/$deviceId');

  /// DELETE /blocks/{deviceId} (idempotent).
  Future<void> unblockUser(String deviceId) =>
      transport.delete<void>('/blocks/$deviceId');

  /// POST /users/{deviceId}/report -> the report number of the receipt.
  Future<int> reportUser(
    String deviceId, {
    required String reason,
    String category = 'terms',
    String? contactEmail,
    bool goodFaith = false,
    String? groupId,
    List<ReportEvidence> messages = const [],
  }) async {
    final response = await transport.post<dynamic>(
      '/users/$deviceId/report',
      data: userReportBody(
        reason: reason,
        category: category,
        contactEmail: contactEmail,
        goodFaith: goodFaith,
        groupId: groupId,
        messages: messages,
      ),
    );
    final data = response.data;
    final id = data is Map ? data['reportId'] : null;
    return id is int ? id : 0;
  }
}

extension PrivacyApi on ApiClient {
  /// DELETE /accounts/{id} with the account's auth key (proof of possession).
  Future<void> deleteAccount(String accountId, String authKey) => transport
      .delete<void>('/accounts/$accountId', data: {'authKey': authKey});

  /// DELETE /devices/{id}; a primary may take its companions along (S9).
  Future<void> deleteDevice(
    String deviceId, {
    bool includeCompanions = false,
  }) => transport.delete<void>(
    '/devices/$deviceId',
    queryParameters: includeCompanions
        ? const {'includeCompanions': 'true'}
        : null,
  );

  /// GET /accounts/{id}/export as the raw JSON text (saved as is).
  Future<String> exportAccountJson(String accountId) =>
      _exportJson('/accounts/$accountId/export');

  /// GET /devices/{id}/export as the raw JSON text (anonymous devices, S11).
  Future<String> exportDeviceJson(String deviceId) =>
      _exportJson('/devices/$deviceId/export');

  Future<String> _exportJson(String path) async {
    final response = await transport.get<String>(
      path,
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '{}';
  }
}
