import 'dart:async';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/groups/group_controller.dart';

class GroupApi extends ApiClient {
  GroupApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> members, {
    String? organizationId,
  }) async => {'groupId': 'server-group'};
}

class PendingGroupApi extends ApiClient {
  PendingGroupApi() : super(baseUrl: 'http://unused');
  final response = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> members, {
    String? organizationId,
  }) => response.future;
}

// W2-F: simulates the server's 503 { error, code: "auditor_unavailable" }
// response to POST /groups/business when the organization's auditor is dead.
class AuditorUnavailableGroupApi extends ApiClient {
  AuditorUnavailableGroupApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> members, {
    String? organizationId,
  }) async {
    final requestOptions = RequestOptions(path: '/groups/business');
    throw DioException(
      requestOptions: requestOptions,
      response: Response(
        requestOptions: requestOptions,
        statusCode: 503,
        data: {'error': 'auditor_unavailable', 'code': 'auditor_unavailable'},
      ),
    );
  }
}

void main() {
  test('creation completes safely after screen disposal', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final api = PendingGroupApi();
    final controller = GroupController(database: db, apiClient: api);
    final pending = controller.createGroup('Team', ['bob']);
    controller.dispose();
    api.response.complete({'groupId': 'server-group'});
    expect(await pending, 'server-group');
    await db.close();
  });
  test('creation persists the server group identity', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final controller = GroupController(database: db, apiClient: GroupApi());
    final id = await controller.createGroup(' Team ', ['bob']);
    expect(id, 'server-group');
    final group = await db.select(db.conversations).getSingle();
    expect(group.id, 'server-group');
    expect(group.title, 'Team');
    controller.dispose();
    await db.close();
  });
  test('creation flags auditorUnavailable on a 503 auditor_unavailable response', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final controller = GroupController(
      database: db,
      apiClient: AuditorUnavailableGroupApi(),
    );
    final id = await controller.createGroup(
      'Deal',
      ['bob'],
      organizationId: 'org1',
    );
    expect(id, isNull);
    expect(controller.auditorUnavailable, isTrue);
    expect(controller.error, isNotNull);
    controller.dispose();
    await db.close();
  });
}
