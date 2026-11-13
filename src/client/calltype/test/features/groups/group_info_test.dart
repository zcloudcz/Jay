import 'package:calltype/features/groups/group_info_controller.dart';
import 'package:calltype/features/groups/group_info_screen.dart';
import 'package:calltype/features/groups/group_topic_service.dart';
import 'package:calltype/features/groups/group_topic_store.dart';
import 'package:calltype/features/groups/group_topic_widgets.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../helpers/fake_group_topics.dart';
import '../../helpers/localized_app.dart';

const _group = 'group-1';
const _me = 'me-device';
const _alice = 'alice-device';
const _bot = 'bot-device';
const _auditor = 'auditor-device';

class FakeGroupApi extends ApiClient {
  FakeGroupApi({this.myRole = 'admin'}) : super(baseUrl: 'http://unused');

  String myRole;
  String aliceRole = 'member';
  final roleCalls = <(String, String)>[];
  DioException? roleError;
  var reads = 0;

  @override
  Future<GroupDetails> getGroup(String groupId) async =>
      GroupDetails(groupId: groupId);

  @override
  Future<List<GroupMemberInfo>> getGroupMemberInfos(String groupId) async {
    reads++;
    return [
      GroupMemberInfo(deviceId: _me, displayName: 'Me', role: myRole),
      GroupMemberInfo(
        deviceId: _alice,
        displayName: 'Alice',
        userHandle: 'CT-ALIC-0001',
        role: aliceRole,
      ),
      const GroupMemberInfo(deviceId: _bot, displayName: 'Hermes', isBot: true),
      const GroupMemberInfo(
        deviceId: _auditor,
        displayName: 'Archiver',
        isBot: true,
        role: 'auditor',
      ),
    ];
  }

  @override
  Future<void> setGroupMemberRole(
    String groupId,
    String deviceId,
    String role,
  ) async {
    roleCalls.add((deviceId, role));
    if (roleError != null) throw roleError!;
    if (deviceId == _alice) aliceRole = role;
  }
}

DioException problem(int status, String code) {
  final options = RequestOptions(path: '/groups/$_group/members/x/role');
  return DioException(
    requestOptions: options,
    response: Response(
      requestOptions: options,
      statusCode: status,
      data: {'error': code, 'code': code},
    ),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<AppDatabase> seed(WidgetTester tester, {String? topic}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await tester.runAsync(() async {
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: _group,
              type: 'group',
              title: const Value('Brno trip'),
            ),
          );
      if (topic != null) {
        await writeGroupTopicIfNewer(
          db,
          _group,
          StoredGroupTopic(topic: topic, version: 1, setBy: _me),
        );
      }
    });
    return db;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<(FakeGroupApi, FakeTopicService)> pumpInfo(
    WidgetTester tester,
    AppDatabase db, {
    String myRole = 'admin',
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeGroupApi(myRole: myRole);
    final topics = FakeTopicService(db, api);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => GroupInfoController(
          database: db,
          apiClient: api,
          groupId: _group,
          selfDeviceId: _me,
          selfIdentityId: _me,
          topics: topics,
        ),
        child: localizedApp(home: const GroupInfoScreen()),
      ),
    );
    await settle(tester);
    return (api, topics);
  }

  Future<void> closeDb(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    // Lets drift's pending stream timers of the disposed watchers run in
    // the fake zone; db.close would wait for them forever otherwise.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  Finder menuOf(String id) => find.byKey(ValueKey('group-member-menu-$id'));

  group('GroupInfoScreen', () {
    testWidgets('shows the name, the full topic and the role labels', (
      tester,
    ) async {
      final db = await seed(tester, topic: 'Line one\nLine two');
      await pumpInfo(tester, db);
      expect(find.text('Brno trip'), findsOneWidget);
      final topic = tester.widget<SelectableText>(
        find.byKey(const ValueKey('group-info-topic')),
      );
      expect(topic.data, 'Line one\nLine two');
      expect(find.text(l10nEn.groupMemberYou), findsOneWidget);
      expect(find.textContaining(l10nEn.groupRoleAdmin), findsOneWidget);
      expect(find.textContaining(l10nEn.groupRoleAuditor), findsOneWidget);
      expect(find.text(l10nEn.groupRoleBot), findsOneWidget);
      await closeDb(tester, db);
    });

    testWidgets('admin: Make admin only for people; no Remove admin for the '
        'only admin', (tester) async {
      final db = await seed(tester);
      await pumpInfo(tester, db);
      expect(menuOf(_alice), findsOneWidget);
      expect(menuOf(_bot), findsNothing, reason: 'bots are never admins');
      expect(menuOf(_auditor), findsNothing, reason: 'auditor immutable');
      expect(menuOf(_me), findsNothing, reason: 'the only admin');
      expect(
        find.byKey(const ValueKey('group-info-edit-topic')),
        findsOneWidget,
      );
      await closeDb(tester, db);
    });

    testWidgets('non-admin: no role menus and no Edit topic', (tester) async {
      final db = await seed(tester, topic: 'Read only');
      await pumpInfo(tester, db, myRole: 'member');
      expect(find.byType(PopupMenuButton<bool>), findsNothing);
      expect(find.byKey(const ValueKey('group-info-edit-topic')), findsNothing);
      expect(find.text('Read only'), findsOneWidget);
      await closeDb(tester, db);
    });

    testWidgets('Make admin calls the server and reloads the list', (
      tester,
    ) async {
      final db = await seed(tester);
      final (api, _) = await pumpInfo(tester, db);
      final reads = api.reads;
      await tester.tap(menuOf(_alice));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-make-admin')));
      await settle(tester);
      expect(api.roleCalls, [(_alice, 'admin')]);
      expect(api.reads, greaterThan(reads));
      // Two admins now: each may be demoted, also the viewer.
      expect(menuOf(_me), findsOneWidget);
      await tester.tap(menuOf(_alice));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-remove-admin')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-make-admin')), findsNothing);
      await closeDb(tester, db);
    });

    testWidgets('a server refusal shows a snack bar', (tester) async {
      final db = await seed(tester);
      final (api, _) = await pumpInfo(tester, db);
      api.aliceRole = 'admin';
      await tester.runAsync(
        () => tester
            .element(find.byType(GroupInfoScreen))
            .read<GroupInfoController>()
            .load(),
      );
      await tester.pumpAndSettle();
      // Another admin demoted themselves meanwhile: the server says last.
      api.roleError = problem(409, 'last_admin');
      await tester.tap(menuOf(_alice));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-remove-admin')));
      await settle(tester);
      expect(find.text(l10nEn.groupRoleErrorLastAdmin), findsOneWidget);
      await closeDb(tester, db);
    });

    testWidgets('Edit topic saves the dialog text and confirms', (
      tester,
    ) async {
      final db = await seed(tester, topic: 'Old');
      final (_, topics) = await pumpInfo(tester, db);
      await tester.tap(find.byKey(const ValueKey('group-info-edit-topic')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('group-topic-field'));
      expect(tester.widget<TextField>(field).maxLength, 4000);
      expect(tester.widget<TextField>(field).controller?.text, 'Old');
      await tester.enterText(field, 'New topic\nwith two lines');
      await tester.tap(find.byKey(const ValueKey('group-topic-save')));
      await settle(tester);
      expect(topics.saved, [(_group, 'New topic\nwith two lines')]);
      expect(find.text(l10nEn.groupTopicSaved), findsOneWidget);
      await closeDb(tester, db);
    });

    testWidgets('an old server shows "not supported" for the topic', (
      tester,
    ) async {
      final db = await seed(tester);
      final (_, topics) = await pumpInfo(tester, db);
      topics.result = const GroupTopicResult.failed(
        GroupTopicError.unsupported,
      );
      await tester.tap(find.byKey(const ValueKey('group-info-edit-topic')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-topic-field')),
        'x',
      );
      await tester.tap(find.byKey(const ValueKey('group-topic-save')));
      await settle(tester);
      expect(find.text(l10nEn.groupTopicErrorUnsupported), findsOneWidget);
      await closeDb(tester, db);
    });

    testWidgets('a GroupChanged hint for this group re-reads the members', (
      tester,
    ) async {
      final db = await seed(tester);
      final api = FakeGroupApi();
      final controller = GroupInfoController(
        database: db,
        apiClient: api,
        groupId: _group,
        selfDeviceId: _me,
        selfIdentityId: _me,
        groupChanged: Stream.fromIterable([
          {'groupId': 'other'},
          {'groupId': _group.toUpperCase()},
        ]),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(api.reads, 1);
      controller.dispose();
      await closeDb(tester, db);
    });
  });

  group('GroupHeaderTitle', () {
    testWidgets('shows the first topic line and opens Group info', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/chats/$_group',
        routes: [
          GoRoute(
            path: '/chats/:id',
            builder: (_, _) => Scaffold(
              appBar: AppBar(
                title: const GroupHeaderTitle(
                  conversationId: _group,
                  name: 'Brno trip',
                  topic: 'First line\nsecond line',
                ),
              ),
            ),
            routes: [
              GoRoute(
                path: 'info',
                builder: (_, state) =>
                    Text('info of ${state.pathParameters['id']}'),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(localizedApp(router: router));
      await tester.pumpAndSettle();
      expect(find.text('Brno trip'), findsOneWidget);
      expect(find.text('First line'), findsOneWidget);
      expect(find.text('second line'), findsNothing);
      final line = tester.widget<Text>(
        find.byKey(const ValueKey('chat-group-topic')),
      );
      expect(line.maxLines, 1);
      expect(line.overflow, TextOverflow.ellipsis);

      await tester.tap(find.byKey(const ValueKey('chat-group-header')));
      await tester.pumpAndSettle();
      expect(find.text('info of $_group'), findsOneWidget);
    });

    testWidgets('no topic: only the name', (tester) async {
      await tester.pumpWidget(
        localizedApp(
          home: const Scaffold(
            body: GroupHeaderTitle(
              conversationId: _group,
              name: 'Brno',
              topic: '',
            ),
          ),
        ),
      );
      expect(find.text('Brno'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-group-topic')), findsNothing);
    });
  });
}
