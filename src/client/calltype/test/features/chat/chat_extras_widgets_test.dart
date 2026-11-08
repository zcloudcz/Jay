import 'dart:convert';

import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/chat/attachment_sheet.dart';
import 'package:calltype/features/chat/pin_widgets.dart';
import 'package:calltype/features/chat/poll_widgets.dart';
import 'package:calltype/features/chat/polls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// Poll card, poll composer and pinned bar (spec 2026-11-08-chat-extras).
void main() {
  PollVote vote(String voter, List<int> options, int at) => PollVote(
    pollId: 'p',
    voterId: voter,
    conversationId: 'c',
    options: jsonEncode(options),
    votedAt: at,
  );

  Message message(String id, String body) => Message(
    id: id,
    conversationId: 'c',
    senderId: 'bob',
    body: body,
    type: 'text',
    status: 'sent',
    createdAt: DateTime.utc(2026),
    forwarded: false,
    deleted: false,
  );

  group('tallyPoll', () {
    test('counts current votes; withdrawn and misfit votes do not count', () {
      final poll = PollPayload.create(question: 'Q', options: ['a', 'b']);
      final results = tallyPoll(poll, [
        vote('bob', [1], 2),
        vote('me', [0], 1),
        vote('carol', [], 3),
        vote('dave', [0, 1], 4),
        vote('erin', [7], 5),
      ], myId: 'ME');
      expect(results.votersByOption, [
        ['me'],
        ['bob'],
      ]);
      expect(results.voterCount, 2);
      expect(results.mine, [0]);
      expect(results.maxCount, 1);
    });
  });

  group('PollCard', () {
    Widget card(
      PollResults results,
      List<List<int>> sent, {
      bool open = true,
    }) => localizedApp(
      home: Scaffold(
        body: PollCard(
          results: results,
          textColor: Colors.black,
          onVote: open ? sent.add : null,
          onShowVoters: () {},
        ),
      ),
    );

    testWidgets('single choice: pick, switch, tap the pick again withdraws', (
      tester,
    ) async {
      final poll = PollPayload.create(question: 'Lunch?', options: ['A', 'B']);
      final sent = <List<int>>[];
      await tester.pumpWidget(
        card(
          tallyPoll(poll, [
            vote('me', [0], 1),
          ], myId: 'me'),
          sent,
        ),
      );
      expect(find.text('Lunch?'), findsOneWidget);
      expect(find.text(l10nEn.pollSelectOne), findsOneWidget);
      expect(find.text(l10nEn.pollVotesCount(1)), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-option-1')));
      await tester.tap(find.byKey(const ValueKey('poll-option-0')));
      expect(sent, [
        [1],
        <int>[],
      ]);
    });

    testWidgets('multiple choice toggles; no voting when closed for the user', (
      tester,
    ) async {
      final poll = PollPayload.create(
        question: 'Days?',
        options: ['Mon', 'Tue', 'Wed'],
        multiple: true,
      );
      final sent = <List<int>>[];
      final results = tallyPoll(poll, [
        vote('me', [2], 1),
      ], myId: 'me');
      await tester.pumpWidget(card(results, sent));
      expect(find.text(l10nEn.pollSelectMany), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-option-0')));
      await tester.tap(find.byKey(const ValueKey('poll-option-2')));
      expect(sent, [
        [0, 2],
        <int>[],
      ]);
      sent.clear();
      await tester.pumpWidget(card(results, sent, open: false));
      await tester.tap(find.byKey(const ValueKey('poll-option-0')));
      expect(sent, isEmpty);
    });

    testWidgets('voters sheet lists names per option', (tester) async {
      final poll = PollPayload.create(question: 'Q', options: ['A', 'B']);
      final results = tallyPoll(poll, [
        vote('bob', [0], 1),
        vote('me', [0], 2),
      ], myId: 'me');
      await tester.pumpWidget(
        localizedApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPollVotersSheet(
                  context,
                  results: results,
                  nameOf: (id) => id == 'me' ? 'You' : 'Bob',
                ),
                child: const Icon(Icons.poll),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.poll));
      await tester.pumpAndSettle();
      expect(find.text('A (2)'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text(l10nEn.pollNoVotes), findsOneWidget);
    });
  });

  group('poll composer', () {
    testWidgets('refuses an incomplete poll, sends a valid one', (
      tester,
    ) async {
      PollPayload? result;
      await tester.pumpWidget(
        localizedApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showPollComposer(context),
                child: const Icon(Icons.add),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.pollCreateTitle), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('poll-question')), 'Q?');
      await tester.enterText(
        find.byKey(const ValueKey('poll-option-field-0')),
        'Same',
      );
      await tester.enterText(
        find.byKey(const ValueKey('poll-option-field-1')),
        'Same',
      );
      await tester.tap(find.byKey(const ValueKey('poll-send')));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.pollInvalid), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('poll-add-option')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('poll-add-option')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('poll-option-field-1')),
        'Other',
      );
      await tester.enterText(
        find.byKey(const ValueKey('poll-option-field-2')),
        'Third',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('poll-multiple')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('poll-multiple')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('poll-send')));
      await tester.pumpAndSettle();
      expect(
        result,
        PollPayload.create(
          question: 'Q?',
          options: ['Same', 'Other', 'Third'],
          multiple: true,
        ),
      );
    });
  });

  group('PinnedMessageBar', () {
    testWidgets('shows the newest pin, a tap jumps and cycles; list opens', (
      tester,
    ) async {
      final pins = [message('p2', 'second'), message('p1', 'first')];
      final jumped = <String>[];
      var listed = 0;
      await tester.pumpWidget(
        localizedApp(
          home: Scaffold(
            body: PinnedMessageBar(
              pins: pins,
              previewOf: (m) => m.body!,
              onJump: (m) => jumped.add(m.id),
              onShowAll: () => listed++,
            ),
          ),
        ),
      );
      expect(find.text('second'), findsOneWidget);
      expect(find.text('${l10nEn.chatPinnedLabel} 1/2'), findsOneWidget);
      await tester.tap(find.text('second'));
      await tester.pump();
      expect(jumped, ['p2']);
      expect(find.text('first'), findsOneWidget);
      await tester.tap(find.text('first'));
      await tester.pump();
      expect(jumped, ['p2', 'p1']);
      expect(find.text('second'), findsOneWidget, reason: 'cycles');
      await tester.tap(find.byKey(const ValueKey('chat-pinned-all')));
      expect(listed, 1);
    });

    testWidgets('nothing when there are no pins; one pin has no counter', (
      tester,
    ) async {
      Widget bar(List<Message> pins) => localizedApp(
        home: Scaffold(
          body: PinnedMessageBar(
            pins: pins,
            previewOf: (m) => m.body!,
            onJump: (_) {},
            onShowAll: () {},
          ),
        ),
      );
      await tester.pumpWidget(bar(const []));
      expect(find.byKey(const ValueKey('chat-pinned-bar')), findsNothing);
      await tester.pumpWidget(bar([message('p', 'only')]));
      expect(find.text(l10nEn.chatPinnedLabel), findsOneWidget);
    });

    testWidgets('the list jumps and unpins', (tester) async {
      final pins = [message('p2', 'second'), message('p1', 'first')];
      final jumped = <String>[];
      final unpinned = <String>[];
      await tester.pumpWidget(
        localizedApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPinnedMessagesSheet(
                  context,
                  pins: pins,
                  previewOf: (m) => m.body!,
                  authorOf: (_) => 'Bob',
                  onJump: (m) => jumped.add(m.id),
                  onUnpin: (m) => unpinned.add(m.id),
                ),
                child: const Icon(Icons.list),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.chatPinnedListTitle), findsOneWidget);
      await tester.tap(find.byTooltip(l10nEn.chatMessageUnpin).last);
      await tester.pumpAndSettle();
      expect(unpinned, ['p1']);
      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(jumped, ['p2']);
    });
  });

  testWidgets('the attachment sheet offers a poll only where allowed', (
    tester,
  ) async {
    AttachSource? picked;
    Future<void> openSheet({required bool poll}) async {
      await tester.pumpWidget(
        localizedApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    picked = await showAttachSourceSheet(context, poll: poll),
                child: const Icon(Icons.attach_file),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
    }

    await openSheet(poll: false);
    expect(find.text(l10nEn.chatAttachPoll), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await openSheet(poll: true);
    await tester.tap(find.text(l10nEn.chatAttachPoll));
    await tester.pumpAndSettle();
    expect(picked, AttachSource.poll);
  });
}
