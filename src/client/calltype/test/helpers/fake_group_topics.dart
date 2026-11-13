import 'package:calltype/features/groups/group_topic_service.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';

/// Records topic saves instead of recording + sending them, for screen
/// tests (the real send path is covered by group_topic_flow_test).
class FakeTopicService extends GroupTopicService {
  FakeTopicService(AppDatabase db, ApiClient api)
    : super(
        database: db,
        apiClient: api,
        sender: () => throw UnimplementedError(),
        directory: () => throw UnimplementedError(),
      );

  final saved = <(String, String)>[];
  GroupTopicResult result = const GroupTopicResult.sent(GroupTopicSent.sent);

  @override
  Future<GroupTopicResult> setTopic(String groupId, String topic) async {
    saved.add((groupId, topic.trim()));
    return result;
  }
}
