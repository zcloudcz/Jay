import 'package:calltype/features/chat/chat_message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

typedef _Msg = ({String id, bool mine});

/// The chat list's "jump to latest" button and its scroll anchoring.
void main() {
  const itemHeight = 50.0;
  final listKey = GlobalKey();

  List<_Msg> history(int n) => [
    // Newest first, like ChatController.messages.
    for (var i = n - 1; i >= 0; i--) (id: 'm$i', mine: false),
  ];

  Widget app(List<_Msg> items) => localizedApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        child: ChatMessageList<_Msg>(
          key: listKey,
          items: items,
          idOf: (m) => m.id,
          isMine: (m) => m.mine,
          itemBuilder: (context, m) => SizedBox(
            height: itemHeight,
            child: Text(m.id, key: ValueKey(m.id)),
          ),
        ),
      ),
    ),
  );

  final button = find.byKey(const ValueKey('chat-jump-to-latest'));
  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  Future<void> scrollUp(WidgetTester tester, double by) async {
    await tester.drag(find.byType(CustomScrollView), Offset(0, by));
    await tester.pumpAndSettle();
  }

  testWidgets('hidden at the bottom, shown after scrolling up a screen', (
    tester,
  ) async {
    await tester.pumpWidget(app(history(100)));
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    expect(find.text('m99'), findsOneWidget);

    await scrollUp(tester, 300);
    expect(button, findsNothing, reason: 'less than one screen up');

    await scrollUp(tester, 500);
    expect(button, findsOneWidget);
    expect(find.byTooltip(l10nEn.chatJumpToLatest), findsOneWidget);

    await scrollUp(tester, -2000);
    expect(button, findsNothing, reason: 'back at the bottom');
  });

  testWidgets('tap scrolls to the newest message, also from far away', (
    tester,
  ) async {
    await tester.pumpWidget(app(history(300)));
    await tester.pumpAndSettle();
    position(tester).jumpTo(200 * itemHeight);
    await tester.pumpAndSettle();
    expect(find.text('m99'), findsOneWidget);
    expect(find.text('m299'), findsNothing);
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('m299'), findsOneWidget);
    expect(position(tester).pixels, position(tester).minScrollExtent);
    expect(button, findsNothing);
  });

  testWidgets('new messages keep the reading position and count on the badge', (
    tester,
  ) async {
    var items = history(100);
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    await scrollUp(tester, 1000);
    final before = tester.getTopLeft(find.text('m70'));

    items = [(id: 'n2', mine: false), (id: 'n1', mine: false), ...items];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('m70')),
      before,
      reason: 'the user is reading history and must not be moved',
    );
    final badge = find.byKey(const ValueKey('chat-jump-to-latest-badge'));
    expect(
      find.descendant(of: badge, matching: find.text('2')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(button.hitTestable().first).label,
      isNot(isEmpty),
    );
    expect(
      find.bySemanticsLabel(
        '${l10nEn.chatJumpToLatest}, ${l10nEn.chatNewMessagesBadge(2)}',
      ),
      findsOneWidget,
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('n2'), findsOneWidget);
    expect(button, findsNothing);

    // Following again: the next message shows at the bottom right away.
    items = [(id: 'n3', mine: false), ...items];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    expect(find.text('n3'), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('at the bottom a new message is shown without a button', (
    tester,
  ) async {
    var items = history(30);
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    items = [(id: 'n1', mine: false), ...items];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    expect(find.text('n1'), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('an own message scrolls to the bottom while reading history', (
    tester,
  ) async {
    var items = history(100);
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    await scrollUp(tester, 1500);
    expect(find.text('m99'), findsNothing);

    items = [(id: 'own', mine: true), (id: 'n1', mine: false), ...items];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    expect(find.text('own'), findsOneWidget);
    expect(button, findsNothing);
  });
}
