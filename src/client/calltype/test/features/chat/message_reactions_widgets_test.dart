import 'package:calltype/features/chat/message_bubble.dart';
import 'package:calltype/features/chat/reaction_widgets.dart';
import 'package:calltype/features/chat/reactions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// The reaction UI of a bubble: quick bar in the long-press sheet (touch)
/// and on top of the three-dots menu (desktop/web), "+" for the full
/// picker, chips under the bubble.
void main() {
  Widget bubble({
    void Function(String emoji)? onReact,
    String? myReaction,
    List<ReactionSummary> reactions = const [],
    void Function(ReactionSummary chip)? onTap,
    void Function(ReactionSummary chip)? onLongPress,
    List<MessageAction> actions = const [],
    Future<String?> Function(BuildContext context)? picker,
  }) => localizedApp(
    home: Scaffold(
      body: MessageBubble(
        text: 'hello',
        time: '10:00',
        isMine: false,
        actions: actions,
        onReact: onReact,
        myReaction: myReaction,
        reactions: reactions,
        onReactionTap: onTap,
        onReactionLongPress: onLongPress,
        pickEmoji: picker ?? (_) async => null,
      ),
    ),
  );

  final reply = MessageAction(
    icon: Icons.reply_rounded,
    label: 'Reply',
    onSelected: () {},
  );

  testWidgets('touch: long-press shows the quick bar above the actions', (
    tester,
  ) async {
    final picked = <String>[];
    await tester.pumpWidget(
      bubble(onReact: picked.add, actions: [reply], myReaction: '❤️'),
    );
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    for (final emoji in quickReactions) {
      expect(find.byKey(ValueKey('quick-reaction:$emoji')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('quick-reaction:more')), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    // The current reaction is marked.
    final selected = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('quick-reaction:❤️')),
        matching: find.byType(Container),
      ),
    );
    expect((selected.decoration! as BoxDecoration).color, isNotNull);

    await tester.tap(find.byKey(const ValueKey('quick-reaction:😂')));
    await tester.pumpAndSettle();
    expect(picked, ['😂']);
    expect(find.text('Reply'), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('"+" opens the full picker and reacts with its pick', (
    tester,
  ) async {
    final picked = <String>[];
    var opened = 0;
    await tester.pumpWidget(
      bubble(
        onReact: picked.add,
        picker: (_) async {
          opened++;
          return '🦄';
        },
      ),
    );
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-reaction:more')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(picked, ['🦄']);
  });

  testWidgets('a closed picker reacts with nothing', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(bubble(onReact: picked.add));
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-reaction:more')));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });

  testWidgets('no onReact: no quick bar (and no sheet without actions)', (
    tester,
  ) async {
    await tester.pumpWidget(bubble(actions: [reply]));
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-reaction:👍')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.pumpWidget(bubble());
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('desktop: the quick bar heads the three-dots menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final picked = <String>[];
    // Reacting alone is enough for a menu, even without other actions.
    await tester.pumpWidget(bubble(onReact: picked.add));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'no overflow');
    await tester.tap(find.byKey(const ValueKey('quick-reaction:🙏')));
    await tester.pumpAndSettle();
    expect(picked, ['🙏']);
    expect(find.byKey(const ValueKey('quick-reaction:🙏')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('chips show emoji and count; tap and long-press report the '
      'chip', (tester) async {
    final taps = <String>[];
    final presses = <String>[];
    await tester.pumpWidget(
      bubble(
        reactions: const [
          ReactionSummary(emoji: '👍', reactorIds: ['a', 'b', 'c'], mine: true),
          ReactionSummary(emoji: '😮', reactorIds: ['d'], mine: false),
        ],
        onTap: (chip) => taps.add(chip.emoji),
        onLongPress: (chip) => presses.add(chip.emoji),
      ),
    );
    expect(find.text('👍 3'), findsOneWidget);
    expect(find.text('😮'), findsOneWidget, reason: 'a count of 1 is implied');
    await tester.tap(find.text('👍 3'));
    await tester.longPress(find.text('😮'));
    await tester.pumpAndSettle();
    expect(taps, ['👍']);
    expect(presses, ['😮']);
  });

  testWidgets('no reactions: no chips', (tester) async {
    await tester.pumpWidget(bubble());
    expect(find.byKey(const ValueKey('reaction-chip:👍')), findsNothing);
  });

  testWidgets('who reacted: names per emoji; the own row removes', (
    tester,
  ) async {
    var removed = 0;
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showReactorsSheet(
              context,
              reactions: const [
                ReactionSummary(
                  emoji: '👍',
                  reactorIds: ['me', 'ann'],
                  mine: true,
                ),
                ReactionSummary(emoji: '😢', reactorIds: ['joe'], mine: false),
              ],
              nameOf: (id) => id == 'me' ? 'You' : id.toUpperCase(),
              myId: 'me',
              onRemoveMine: () => removed++,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatReactionsTitle), findsOneWidget);
    expect(find.text('ANN'), findsOneWidget);
    expect(find.text('JOE'), findsOneWidget);
    expect(find.text(l10nEn.chatReactionTapToRemove), findsOneWidget);
    await tester.tap(find.text('ANN'));
    await tester.pumpAndSettle();
    expect(removed, 0, reason: 'only the own row removes');
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(removed, 1);
    expect(find.text('JOE'), findsNothing, reason: 'the sheet closed');
  });
}
