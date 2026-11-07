import 'dart:async';

import 'package:calltype/app/keyboard_dismiss.dart';
import 'package:calltype/features/chat/message_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// The chat composer: per-conversation drafts, the multiline field and what
/// Enter does per platform, and dismissing the keyboard (iOS beta findings).
void main() {
  Widget input({
    Future<void> Function(String)? onSend,
    String? initialText,
    Future<String?> Function()? loadDraft,
    Future<void> Function(String)? saveDraft,
    bool? enterSends,
    Widget? above,
  }) => localizedApp(
    home: KeyboardDismiss(
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child:
                  above ??
                  ListView(
                    children: [
                      for (var i = 0; i < 60; i++)
                        SizedBox(height: 40, child: Text('row $i')),
                    ],
                  ),
            ),
            MessageInput(
              onSend: onSend ?? (_) async {},
              initialText: initialText,
              loadDraft: loadDraft,
              saveDraft: saveDraft,
              enterSends: enterSends,
            ),
          ],
        ),
      ),
    ),
  );

  TextField field(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  group('draft', () {
    testWidgets('a stored draft is restored when the chat opens', (
      tester,
    ) async {
      await tester.pumpWidget(input(loadDraft: () async => 'unsent words'));
      await tester.pump();
      expect(field(tester).controller!.text, 'unsent words');
      expect(field(tester).controller!.selection.baseOffset, 12);
    });

    testWidgets('an explicit initial text (bot deep link) wins over the '
        'stored draft and replaces it', (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        input(
          initialText: '/start abc',
          loadDraft: () async => 'old draft',
          saveDraft: (t) async => saved.add(t),
        ),
      );
      await tester.pump();
      expect(field(tester).controller!.text, '/start abc');
      expect(saved, ['/start abc']);
    });

    testWidgets('typing is saved after a pause; sending clears the draft', (
      tester,
    ) async {
      final saved = <String>[];
      final sent = <String>[];
      await tester.pumpWidget(
        input(
          loadDraft: () async => null,
          saveDraft: (t) async => saved.add(t),
          onSend: (t) async => sent.add(t),
        ),
      );
      await tester.enterText(find.byType(TextField), 'hel');
      await tester.enterText(find.byType(TextField), 'hello');
      expect(saved, isEmpty, reason: 'debounced');
      await tester.pump(const Duration(seconds: 1));
      expect(saved, ['hello']);

      await tester.tap(find.byTooltip(l10nEn.chatInputSend));
      await tester.pump();
      expect(sent, ['hello']);
      expect(field(tester).controller!.text, isEmpty);
      expect(saved, ['hello', ''], reason: 'cleared at once, not debounced');
    });

    testWidgets('going to the background saves at once', (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        input(
          loadDraft: () async => null,
          saveDraft: (t) async => saved.add(t),
        ),
      );
      await tester.enterText(find.byType(TextField), 'before the kill');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(saved, ['before the kill']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('leaving the chat saves the pending text', (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        input(
          loadDraft: () async => null,
          saveDraft: (t) async => saved.add(t),
        ),
      );
      await tester.enterText(find.byType(TextField), 'leaving');
      await tester.pumpWidget(const SizedBox());
      expect(saved, ['leaving']);
    });

    testWidgets('a slow draft load does not overwrite what the user typed', (
      tester,
    ) async {
      final load = Completer<String?>();
      await tester.pumpWidget(input(loadDraft: () => load.future));
      await tester.enterText(find.byType(TextField), 'new');
      load.complete('old');
      await tester.pump();
      expect(field(tester).controller!.text, 'new');
    });
  });

  group('multiline', () {
    testWidgets('grows from one line to six and is a multiline keyboard', (
      tester,
    ) async {
      await tester.pumpWidget(input(enterSends: false));
      final f = field(tester);
      expect(f.minLines, 1);
      expect(f.maxLines, MessageInput.maxComposerLines);
      expect(f.keyboardType, TextInputType.multiline);
      expect(f.textInputAction, TextInputAction.newline);
      final oneLine = tester.getSize(find.byType(TextField)).height;
      await tester.enterText(find.byType(TextField), 'a\nb\nc');
      await tester.pump();
      final threeLines = tester.getSize(find.byType(TextField)).height;
      expect(threeLines, greaterThan(oneLine));
      await tester.enterText(
        find.byType(TextField),
        List.generate(20, (i) => 'line $i').join('\n'),
      );
      await tester.pump();
      final capped = tester.getSize(find.byType(TextField)).height;
      expect(capped, greaterThan(threeLines));
      expect(capped, lessThan(oneLine * 7), reason: 'scrolls inside');
      // The send button stays on the bottom line.
      expect(
        tester.getBottomLeft(find.byTooltip(l10nEn.chatInputSend)).dy,
        closeTo(tester.getBottomLeft(find.byType(TextField)).dy, 8),
      );
    });

    testWidgets('mobile: Enter is a new line, only the button sends', (
      tester,
    ) async {
      final sent = <String>[];
      await tester.pumpWidget(
        input(enterSends: false, onSend: (t) async => sent.add(t)),
      );
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isEmpty);
      await tester.tap(find.byTooltip(l10nEn.chatInputSend));
      await tester.pump();
      expect(sent, ['hi']);
    });

    testWidgets('web / desktop: Enter sends, Shift+Enter does not', (
      tester,
    ) async {
      final sent = <String>[];
      await tester.pumpWidget(
        input(enterSends: true, onSend: (t) async => sent.add(t)),
      );
      await tester.enterText(find.byType(TextField), 'first line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sent, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, ['first line']);
      expect(field(tester).controller!.text, isEmpty);
    });

    testWidgets('Enter while an IME is composing commits, does not send', (
      tester,
    ) async {
      final sent = <String>[];
      await tester.pumpWidget(
        input(enterSends: true, onSend: (t) async => sent.add(t)),
      );
      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'nihon',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isEmpty);
    });
  });

  group('keyboard dismissal', () {
    testWidgets('a touch tap outside the field unfocuses it (also on '
        'iOS / Android, where Flutter only does that for a mouse)', (
      tester,
    ) async {
      await tester.pumpWidget(input());
      await tester.showKeyboard(find.byType(TextField));
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text('row 0'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('tapping send or attach keeps the keyboard up', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(input(onSend: (t) async => sent.add(t)));
      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.tap(find.byTooltip(l10nEn.chatInputSend));
      await tester.pump();
      expect(sent, ['x']);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byTooltip(l10nEn.chatInputAttach));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('a tap outside still reaches the button it hit', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        input(
          above: Center(
            child: TextButton(onPressed: () => taps++, child: const Text('b')),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.tap(find.text('b'));
      await tester.pump();
      expect(taps, 1);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('dragging a list dismisses the keyboard', (tester) async {
      await tester.pumpWidget(input());
      await tester.showKeyboard(find.byType(TextField));
      await tester.drag(find.text('row 3'), const Offset(0, -200));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });
}
