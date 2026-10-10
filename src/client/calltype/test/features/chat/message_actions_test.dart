import 'package:calltype/features/chat/message_bubble.dart';
import 'package:calltype/features/chat/message_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

List<MessageAction> _actions(List<String> log) => [
  MessageAction(
    icon: Icons.reply_rounded,
    label: 'Reply',
    onSelected: () => log.add('reply'),
  ),
  MessageAction(
    icon: Icons.delete_outline_rounded,
    label: 'Delete',
    destructive: true,
    onSelected: () => log.add('delete'),
  ),
];

Widget _bubble({
  List<MessageAction> actions = const [],
  String? quoteAuthor,
  String? quoteText,
  bool forwarded = false,
  bool deleted = false,
  Widget? content,
}) => localizedApp(
  home: Scaffold(
    body: MessageBubble(
      text: 'hello',
      time: '10:00',
      isMine: true,
      actions: actions,
      quoteAuthor: quoteAuthor,
      quoteText: quoteText,
      forwarded: forwarded,
      deleted: deleted,
      content: content,
    ),
  ),
);

void main() {
  testWidgets('desktop: the three dots list every action and run it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final log = <String>[];
    await tester.pumpWidget(_bubble(actions: _actions(log)));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(log, ['delete']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('touch: long-press sheet lists every action and runs it', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_bubble(actions: _actions(log)));
    expect(find.byIcon(Icons.more_vert), findsNothing);
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(log, ['reply']);
  });

  testWidgets('no actions: no menu button and no long-press sheet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(_bubble());
    expect(find.byIcon(Icons.more_vert), findsNothing);
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('quote and forwarded line render above the text', (tester) async {
    await tester.pumpWidget(
      _bubble(quoteAuthor: 'Bob', quoteText: 'original', forwarded: true),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('original'), findsOneWidget);
    expect(find.text(l10nEn.chatMessageForwarded), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('content replaces the text', (tester) async {
    await tester.pumpWidget(_bubble(content: const Text('file.bin')));
    expect(find.text('file.bin'), findsOneWidget);
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('deleted shows the placeholder only', (tester) async {
    await tester.pumpWidget(
      _bubble(
        deleted: true,
        quoteText: 'original',
        forwarded: true,
        content: const Text('file.bin'),
      ),
    );
    expect(find.text(l10nEn.chatMessageDeleted), findsOneWidget);
    expect(find.text('hello'), findsNothing);
    expect(find.text('original'), findsNothing);
    expect(find.text('file.bin'), findsNothing);
    expect(find.text(l10nEn.chatMessageForwarded), findsNothing);
  });

  testWidgets('reply bar shows author and text; close calls onCancelReply', (
    tester,
  ) async {
    var cancelled = 0;
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MessageInput(
              onSend: (_) async {},
              replyAuthor: 'Bob',
              replyText: 'quoted text',
              onCancelReply: () => cancelled++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('quoted text'), findsOneWidget);
    await tester.tap(find.byTooltip(l10nEn.chatReplyCancel));
    expect(cancelled, 1);
  });

  testWidgets('no reply text means no reply bar', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(body: MessageInput(onSend: (_) async {})),
      ),
    );
    expect(find.byTooltip(l10nEn.chatReplyCancel), findsNothing);
  });
}
