import 'dart:async';
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
    List<String> members,
  ) async => {'groupId': 'server-group'};
}

class PendingGroupApi extends ApiClient {
  PendingGroupApi() : super(baseUrl: 'http://unused');
  final response = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> createGroup(String name, List<String> members) =>
      response.future;
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
}
