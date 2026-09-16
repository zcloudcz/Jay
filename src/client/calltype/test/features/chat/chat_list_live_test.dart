import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'chat list observes conversations arriving while the screen is open',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final controller = ChatListController(database: db);
      addTearDown(() async {
        controller.dispose();
        await db.close();
      });
      await controller.loadConversations();
      await db
          .into(db.conversations)
          .insert(ConversationsCompanion.insert(id: 'peer', type: 'direct'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controller.conversations.map((c) => c.id), ['peer']);
    },
  );
}
