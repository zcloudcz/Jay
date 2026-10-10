import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Answers every request with a fixed JSON body, so the parsing of
/// `GET /groups/{id}/members` can be tested without a server.
class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.body);
  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

ApiClient _client(Object body) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = _JsonAdapter(body);
  return ApiClient(baseUrl: 'https://api.test', dio: dio);
}

void main() {
  test('parses the new member shape', () async {
    final members = await _client([
      {
        'deviceId': 'd1',
        'role': 'member',
        'joinedAt': '2026-01-01T00:00:00Z',
        'userHandle': 'CT-AAAA-BBBB',
        'displayName': 'Hermes',
        'isBot': true,
      },
    ]).getGroupMemberInfos('g');

    expect(members.single.deviceId, 'd1');
    expect(members.single.userHandle, 'CT-AAAA-BBBB');
    expect(members.single.displayName, 'Hermes');
    expect(members.single.isBot, isTrue);
  });

  test('parses the old member shape (no profile fields)', () async {
    final members = await _client([
      {'deviceId': 'd1', 'role': 'admin', 'joinedAt': '2026-01-01T00:00:00Z'},
    ]).getGroupMemberInfos('g');

    expect(members.single.deviceId, 'd1');
    expect(members.single.userHandle, isNull);
    expect(members.single.displayName, isNull);
    expect(members.single.isBot, isFalse);
  });

  test('getGroupMembers still returns plain ids', () async {
    final ids = await _client([
      {'deviceId': 'd1', 'userHandle': 'CT-AAAA-BBBB'},
    ]).getGroupMembers('g');
    expect(ids, ['d1']);
  });
}
