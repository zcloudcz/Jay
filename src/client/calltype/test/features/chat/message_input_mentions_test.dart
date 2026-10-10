import 'package:calltype/features/chat/mentions.dart';
import 'package:calltype/features/chat/message_bubble.dart';
import 'package:calltype/features/chat/message_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

const _hermes = MentionCandidate(
  label: 'Boss bot',
  token: 'Hermes',
  detail: 'CT-AAAA-BBBB',
  isBot: true,
);

Widget _input(List<MentionCandidate> candidates) => localizedApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: MessageInput(onSend: (_) async {}, mentionCandidates: candidates),
    ),
  ),
);

void main() {
  testWidgets('typing @ shows suggestions; tapping inserts the token', (
    tester,
  ) async {
    await tester.pumpWidget(_input(const [_hermes]));
    await tester.enterText(find.byType(TextField), '@he');
    await tester.pump();
    expect(find.text('Boss bot'), findsOneWidget);
    expect(find.text('CT-AAAA-BBBB'), findsOneWidget);

    await tester.tap(find.text('Boss bot'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '@Hermes ');
    expect(field.controller!.selection.baseOffset, 8);
    expect(find.text('Boss bot'), findsNothing);
  });

  testWidgets('no candidates means no list', (tester) async {
    await tester.pumpWidget(_input(const []));
    await tester.enterText(find.byType(TextField), '@he');
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('non-matching query hides the list', (tester) async {
    await tester.pumpWidget(_input(const [_hermes]));
    await tester.enterText(find.byType(TextField), '@zzz');
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
  });

  Widget bubble(VoidCallback onCopy) => localizedApp(
    home: Scaffold(
      body: MessageBubble(
        text: 'hello',
        time: '10:00',
        isMine: false,
        actions: [
          MessageAction(
            icon: Icons.copy_rounded,
            label: l10nEn.chatMessageCopy,
            onSelected: onCopy,
          ),
        ],
      ),
    ),
  );

  testWidgets('touch: long-press opens a sheet whose Copy calls onCopy', (
    tester,
  ) async {
    var copies = 0;
    await tester.pumpWidget(bubble(() => copies++));
    // No mouse expected on a phone, so no extra button clutters the bubble.
    expect(find.byIcon(Icons.more_vert), findsNothing);
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10nEn.chatMessageCopy));
    await tester.pumpAndSettle();
    expect(copies, 1);
  });

  testWidgets('desktop/web: a visible three-dots menu offers Copy', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var copies = 0;
    await tester.pumpWidget(bubble(() => copies++));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10nEn.chatMessageCopy));
    await tester.pumpAndSettle();
    expect(copies, 1);
    debugDefaultTargetPlatformOverride = null;
  });
}
