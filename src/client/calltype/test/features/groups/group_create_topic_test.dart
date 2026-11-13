import 'package:calltype/features/groups/group_create_screen.dart';
import 'package:calltype/features/groups/group_topic_service.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/fake_group_topics.dart';

const _me = 'me-identity';

/// POST /groups and GET /groups/{id}/members of the source group (T6).
class CreateApi extends ApiClient {
  CreateApi() : super(baseUrl: 'http://unused');

  final created = <(String, List<String>)>[];

  @override
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> memberDeviceIds, {
    String? organizationId,
  }) async {
    created.add((name, memberDeviceIds));
    return {'groupId': 'new-group'};
  }

  @override
  Future<List<GroupMemberInfo>> getGroupMemberInfos(String groupId) async => [
    const GroupMemberInfo(deviceId: _me, role: 'admin'),
    // A contact, but the server sends the id in another case.
    const GroupMemberInfo(deviceId: 'BOB', displayName: 'Bob'),
    // Not a contact: listed by the server profile.
    const GroupMemberInfo(
      deviceId: 'bot-1',
      displayName: 'Hermes',
      userHandle: 'CT-HERM-0001',
      isBot: true,
    ),
    const GroupMemberInfo(
      deviceId: 'aud',
      displayName: 'Arch',
      role: 'auditor',
    ),
  ];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<AppDatabase> seed(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await tester.runAsync(() async {
      for (final id in ['bob', 'carol']) {
        await db
            .into(db.contacts)
            .insert(
              ContactsCompanion.insert(
                deviceId: id,
                userHandle: 'CT-${id.toUpperCase()}',
                displayName: Value(id == 'bob' ? 'Bob' : 'Carol'),
                identityKey: Uint8List(32),
                addedAt: DateTime(2026),
              ),
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

  Future<void> pumpCreate(
    WidgetTester tester,
    AppDatabase db,
    ApiClient api,
    GroupTopicService? topics, {
    String location = '/groups/create',
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/groups/create',
          builder: (_, state) => GroupCreateScreen(
            organizationId: state.uri.queryParameters['orgId'],
            membersFromGroupId: state.uri.queryParameters['from'],
            selfIdentityId: _me,
          ),
        ),
        GoRoute(
          path: '/chats/:id',
          builder: (_, state) => Text('chat ${state.pathParameters['id']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          Provider<ApiClient>.value(value: api),
          Provider<GroupTopicService?>.value(value: topics),
        ],
        child: localizedApp(router: router),
      ),
    );
    await settle(tester);
  }

  Future<void> closeDb(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  Finder nameField() => find.byType(TextField).first;
  Finder topicField() => find.byKey(const ValueKey('group-topic-field'));

  testWidgets('create with a topic records and sends it, then opens the '
      'chat', (tester) async {
    final db = await seed(tester);
    final api = CreateApi();
    final topics = FakeTopicService(db, api);
    await pumpCreate(tester, db, api, topics);
    expect(tester.widget<TextField>(topicField()).maxLength, 4000);
    await tester.enterText(nameField(), 'Trip');
    await tester.enterText(topicField(), '  Plan the trip  ');
    await tester.tap(find.text('Bob'));
    await tester.pump();
    await tester.tap(find.text(l10nEn.groupCreate));
    await settle(tester);
    expect(api.created.single.$1, 'Trip');
    expect(topics.saved, [('new-group', 'Plan the trip')]);
    expect(find.text('chat new-group'), findsOneWidget);
    await closeDb(tester, db);
  });

  testWidgets('no topic entered: nothing recorded', (tester) async {
    final db = await seed(tester);
    final api = CreateApi();
    final topics = FakeTopicService(db, api);
    await pumpCreate(tester, db, api, topics);
    await tester.enterText(nameField(), 'Trip');
    await tester.tap(find.text('Bob'));
    await tester.pump();
    await tester.tap(find.text(l10nEn.groupCreate));
    await settle(tester);
    expect(topics.saved, isEmpty);
    expect(find.text('chat new-group'), findsOneWidget);
    await closeDb(tester, db);
  });

  testWidgets('a failed topic keeps the group: snack and the chat opens', (
    tester,
  ) async {
    final db = await seed(tester);
    final api = CreateApi();
    final topics = FakeTopicService(db, api)
      ..result = const GroupTopicResult.failed(GroupTopicError.unsupported);
    await pumpCreate(tester, db, api, topics);
    await tester.enterText(nameField(), 'Trip');
    await tester.enterText(topicField(), 'Topic');
    await tester.tap(find.text('Bob'));
    await tester.pump();
    await tester.tap(find.text(l10nEn.groupCreate));
    await settle(tester);
    expect(api.created, hasLength(1));
    expect(find.text('chat new-group'), findsOneWidget);
    expect(find.text(l10nEn.groupTopicCreateFailed), findsOneWidget);
    await closeDb(tester, db);
  });

  testWidgets('business groups have no topic field', (tester) async {
    final db = await seed(tester);
    final api = CreateApi();
    await pumpCreate(
      tester,
      db,
      api,
      null,
      location: '/groups/create?orgId=org-1',
    );
    expect(topicField(), findsNothing);
    await closeDb(tester, db);
  });

  testWidgets('T6: every member of the source group is pre-selected, minus '
      'self and the auditor; non-contacts by their server profile', (
    tester,
  ) async {
    final db = await seed(tester);
    final api = CreateApi();
    await pumpCreate(
      tester,
      db,
      api,
      FakeTopicService(db, api),
      location: '/groups/create?from=old-group',
    );
    bool checked(String id) => tester
        .widget<CheckboxListTile>(
          find.byKey(ValueKey('group-create-member-$id')),
        )
        .value!;
    expect(checked('bob'), isTrue, reason: 'contact matched ignoring case');
    expect(checked('carol'), isFalse, reason: 'not in the source group');
    expect(find.text('Hermes'), findsOneWidget);
    expect(find.text('CT-HERM-0001'), findsOneWidget);
    expect(checked('bot-1'), isTrue);
    expect(find.text('Arch'), findsNothing);
    expect(
      find.byKey(const ValueKey('group-create-member-$_me')),
      findsNothing,
    );
    expect(find.text(l10nEn.groupSelectedCount(2)), findsOneWidget);

    await tester.enterText(nameField(), 'Second topic');
    await tester.pump();
    await tester.tap(find.text(l10nEn.groupCreate));
    await settle(tester);
    expect(api.created.single.$2, unorderedEquals(['bob', 'bot-1']));
    await closeDb(tester, db);
  });
}
