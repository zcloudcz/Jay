import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/polls.dart';
import 'package:calltype/features/media/media_message.dart';
import 'package:calltype/features/search/message_search.dart';
import 'package:calltype/features/search/search_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// Message search (spec 2026-11-08-chat-extras): local only, case and
/// diacritics insensitive, no deleted / control / file rows.
void main() {
  late AppDatabase db;
  var order = 0;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    order = 0;
  });

  tearDown(() => db.close());

  Future<void> add(
    String id,
    String? body, {
    String conversationId = 'bob',
    String senderId = 'bob',
    String type = 'text',
    bool deleted = false,
  }) => db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          senderId: senderId,
          body: Value(body),
          type: Value(type),
          deleted: Value(deleted),
          // Later rows are newer.
          createdAt: DateTime.utc(2026, 11, 1).add(Duration(hours: order++)),
        ),
      );

  Future<List<String>> ids(String query, {String? conversationId}) async =>
      (await searchMessages(
        db,
        query,
        conversationId: conversationId,
      )).hits.map((h) => h.message.id).toList();

  group('searchMessages', () {
    test('ignores case and Latin diacritics, newest first', () async {
      await add('a', 'Příliš žluťoučký kůň');
      await add('b', 'PRILIS pozde');
      await add('c', 'nothing here');
      expect(await ids('prilis'), ['b', 'a']);
      expect(await ids('PŘÍLIŠ'), ['b', 'a']);
      expect(await ids('kun'), ['a']);
      expect(await ids('   '), isEmpty);
    });

    test(
      'skips deleted, control rows, files, call lines and device notices',
      () async {
        await add('text', 'budget plan');
        await add('gone', 'budget plan', deleted: true);
        await add('edit', 'budget plan', type: 'edit');
        await add('pin', '{"targetId":"budget","pinned":true}', type: 'pin');
        await add('file', '{"name":"budget.pdf","data":"AA=="}', type: 'file');
        await add('call', '{"outcome":"budget"}', type: 'call-event');
        await add('device', 'budget', type: 'device-change');
        expect(await ids('budget'), ['text']);
      },
    );

    test('finds poll questions and options and media captions, never the '
        'media JSON', () async {
      await add(
        'poll',
        PollPayload.create(
          question: 'Where to eat?',
          options: ['Pizza place', 'Sushi bar'],
        ).encode(),
        type: pollMessageType,
      );
      final media = MediaInfo(
        id: '0b0b0b0b-0000-4000-8000-000000000001',
        kind: MediaKind.image,
        name: 'holiday.jpg',
        mime: 'image/jpeg',
        size: 10,
        sha256: Uint8List(32),
        key: Uint8List(32),
        nonce: Uint8List(7),
        expiresAt: DateTime.utc(2026, 12),
        caption: 'Beach sunset',
      );
      await add('media', media.encode(), type: 'media');
      expect(await ids('sushi'), ['poll']);
      expect(await ids('where'), ['poll']);
      expect(await ids('sunset'), ['media']);
      expect(await ids('holiday'), isEmpty, reason: 'file names not searched');
      expect(await ids('0b0b0b0b'), isEmpty, reason: 'no JSON keys');
    });

    test('limits to one conversation when asked', () async {
      await add('x', 'release notes', conversationId: 'bob');
      await add('y', 'release party', conversationId: 'g');
      expect(await ids('release'), ['y', 'x']);
      expect(await ids('release', conversationId: 'bob'), ['x']);
    });

    test('pages through the history and stops at the limit', () async {
      for (var i = 0; i < 30; i++) {
        await add('m$i', i.isEven ? 'match $i' : 'other $i');
      }
      final all = await searchMessages(db, 'match', pageSize: 4);
      expect(all.hits, hasLength(15));
      expect(all.limited, isFalse);
      expect(all.hits.first.message.id, 'm28');
      final cut = await searchMessages(db, 'match', limit: 5, pageSize: 4);
      expect(cut.hits, hasLength(5));
      expect(cut.limited, isTrue);
    });
  });

  test('snippet keeps the match position and marks cut ends', () {
    final text = '${'word ' * 30}Needle in the haystack ${'tail ' * 60}';
    final hit = SearchHit(
      message: Message(
        id: 'm',
        conversationId: 'c',
        senderId: 's',
        body: text,
        type: 'text',
        status: 'sent',
        createdAt: DateTime.utc(2026),
        forwarded: false,
        deleted: false,
      ),
      text: text,
      matchStart: text.indexOf('Needle'),
      matchLength: 6,
    );
    final snippet = searchSnippet(hit);
    expect(snippet.text, startsWith('…'));
    expect(snippet.text, endsWith('…'));
    expect(
      snippet.text.substring(snippet.start, snippet.start + snippet.length),
      'Needle',
    );
    expect(foldForSearch('ŽLUŤOUČKÝ'), 'zlutoucky');
    expect(foldForSearch('İx').length, 2, reason: 'one unit per unit');
  });

  group('SearchScreen', () {
    Widget screen({String? conversationId, required List<SearchHit> opened}) =>
        localizedApp(
          home: SearchScreen(
            database: db,
            myIdentityId: 'me',
            conversationId: conversationId,
            conversationTitle: (id) => id == 'g' ? 'Team' : 'Bob',
            senderName: (id) => id == 'bob' ? 'Bob' : id,
            onOpen: opened.add,
            debounce: Duration.zero,
          ),
        );

    testWidgets('shows conversation, sender, highlighted snippet; tap opens', (
      tester,
    ) async {
      final opened = <SearchHit>[];
      await tester.runAsync(() async {
        await add('m1', 'Deploy on Friday', conversationId: 'g');
        await add('m2', 'no deploy today', senderId: 'me');
      });
      await tester.pumpWidget(screen(opened: opened));
      expect(find.text(l10nEn.searchPrompt), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'deploy',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.text('Bob · You'), findsOneWidget);
      expect(find.text('Team · Bob'), findsOneWidget);
      final rich = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const ValueKey('search-hit:m1')),
              matching: find.byType(Text),
            )
            .at(1),
      );
      final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans[1].text, 'Deploy');
      expect(spans[1].style?.fontWeight, FontWeight.bold);

      await tester.tap(find.byKey(const ValueKey('search-hit:m1')));
      expect(opened.single.message.id, 'm1');
    });

    testWidgets('in one chat: only the sender is shown; no hits says so', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await add('m1', 'hello there', conversationId: 'bob');
        await add('m2', 'hello team', conversationId: 'g');
      });
      await tester.pumpWidget(screen(conversationId: 'bob', opened: []));
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'hello',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('search-hit:m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-hit:m2')), findsNothing);
      expect(find.text('Bob'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'zebra',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.text(l10nEn.searchNoResults), findsOneWidget);
    });
  });
}
