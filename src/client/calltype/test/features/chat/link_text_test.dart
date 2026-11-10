import 'package:calltype/features/chat/link_text.dart';
import 'package:calltype/features/chat/message_bubble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// Records launched Uris; [result] is what the platform "answers".
class FakeLauncher {
  final launched = <Uri>[];
  bool result = true;

  Future<bool> call(Uri uri) async {
    launched.add(uri);
    return result;
  }
}

final _theme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
);

Widget _bubble(
  String text,
  FakeLauncher launcher, {
  bool isMine = false,
  List<String>? log,
  String? quoteText,
  bool edited = false,
  ThemeData? theme,
}) => localizedApp(
  theme: theme ?? _theme,
  home: Scaffold(
    body: MessageBubble(
      text: text,
      time: '10:00',
      isMine: isMine,
      edited: edited,
      quoteAuthor: quoteText == null ? null : 'Alice',
      quoteText: quoteText,
      launchLink: launcher.call,
      actions: log == null
          ? const []
          : [
              MessageAction(
                icon: Icons.reply_rounded,
                label: 'Reply',
                onSelected: () => log.add('reply'),
              ),
            ],
    ),
  ),
);

Finder get _body => find.descendant(
  of: find.byType(LinkifiedText),
  matching: find.byType(RichText),
);

/// Every leaf span of the message body.
List<TextSpan> _spans(WidgetTester tester) {
  final result = <TextSpan>[];
  tester.widget<RichText>(_body).text.visitChildren((span) {
    if (span is TextSpan && span.text != null) result.add(span);
    return true;
  });
  return result;
}

/// Global center of the first glyph box of [linkText] in the message body.
Offset _center(WidgetTester tester, String linkText) {
  final paragraph = tester.renderObject<RenderParagraph>(_body);
  final plain = paragraph.text.toPlainText();
  final start = plain.indexOf(linkText);
  expect(start, greaterThanOrEqualTo(0), reason: linkText);
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + linkText.length),
      )
      .first;
  return paragraph.localToGlobal(box.toRect().center);
}

void main() {
  late List<String?> clipboard;

  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugLinkLauncherOverride = null;
  });

  testWidgets('tap on a link launches its Uri, tap on text does not', (
    tester,
  ) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(_bubble('Mrkni na www.seznam.cz prosím', launcher));
    await tester.tapAt(_center(tester, 'Mrkni'));
    await tester.pump();
    expect(launcher.launched, isEmpty);
    await tester.tapAt(_center(tester, 'www.seznam.cz'));
    await tester.pump();
    expect(launcher.launched, [Uri.parse('https://www.seznam.cz')]);
  });

  testWidgets('e-mail address launches mailto', (tester) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(_bubble('martin@zcloud.cz', launcher));
    await tester.tapAt(_center(tester, 'martin@zcloud.cz'));
    await tester.pump();
    expect(launcher.launched, [Uri.parse('mailto:martin@zcloud.cz')]);
  });

  testWidgets('long press on a link shows the link sheet; Copy copies it', (
    tester,
  ) async {
    final launcher = FakeLauncher();
    final log = <String>[];
    const url = 'https://cs.wikipedia.org/wiki/Brno_(město)';
    await tester.pumpWidget(_bubble('viz $url.', launcher, log: log));
    await tester.longPressAt(_center(tester, url));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatLinkOpen), findsOneWidget);
    expect(find.text(l10nEn.chatLinkCopy), findsOneWidget);
    // The full URL, not shortened, and not the message menu.
    expect(
      find.descendant(
        of: find.byKey(const Key('link-sheet-url')),
        matching: find.text(url),
      ),
      findsOneWidget,
    );
    expect(find.text('Reply'), findsNothing);
    await tester.tap(find.text(l10nEn.chatLinkCopy));
    await tester.pumpAndSettle();
    expect(clipboard, [url]);
    expect(find.text(l10nEn.chatLinkCopied), findsOneWidget);
    expect(launcher.launched, isEmpty);
    expect(log, isEmpty);
  });

  testWidgets('Open link in the sheet launches it', (tester) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(_bubble('https://a.cz/x?q=1#f', launcher));
    await tester.longPressAt(_center(tester, 'https://a.cz/x?q=1#f'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10nEn.chatLinkOpen));
    await tester.pumpAndSettle();
    expect(launcher.launched, [Uri.parse('https://a.cz/x?q=1#f')]);
  });

  testWidgets('long press outside the link still opens the message menu', (
    tester,
  ) async {
    final launcher = FakeLauncher();
    final log = <String>[];
    await tester.pumpWidget(
      _bubble('Ahoj, tady https://a.cz', launcher, log: log),
    );
    await tester.longPressAt(_center(tester, 'Ahoj'));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatLinkOpen), findsNothing);
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(log, ['reply']);
    // Outside the text (the time row) too.
    await tester.longPress(find.text('10:00'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
  });

  testWidgets('right click on a link opens the link sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final launcher = FakeLauncher();
    final log = <String>[];
    await tester.pumpWidget(
      _bubble('see https://a.cz now', launcher, log: log),
    );
    await tester.tapAt(
      _center(tester, 'https://a.cz'),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatLinkCopy), findsOneWidget);
    expect(launcher.launched, isEmpty);
    // The three-dots message menu is still there.
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a link shows the click cursor', (tester) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(_bubble('see https://a.cz now', launcher));
    final link = _spans(tester).singleWhere((s) => s.text == 'https://a.cz');
    expect(link.mouseCursor, SystemMouseCursors.click);
    expect(link.recognizer, isA<TapGestureRecognizer>());
  });

  testWidgets('mention and link in one message', (tester) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(
      _bubble('@Hermes viz https://a.cz/x a napiš', launcher, edited: true),
    );
    final spans = _spans(tester);
    expect(spans.map((s) => s.text), [
      '@Hermes viz ',
      'https://a.cz/x',
      ' a napiš',
    ]);
    expect(spans.first.recognizer, isNull);
    expect(find.text(l10nEn.chatMessageEdited), findsOneWidget);
    await tester.tapAt(_center(tester, 'https://a.cz/x'));
    await tester.pump();
    expect(launcher.launched, [Uri.parse('https://a.cz/x')]);
  });

  for (final brightness in Brightness.values) {
    testWidgets('link color in own and other bubbles ($brightness)', (
      tester,
    ) async {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: brightness,
        ),
      );
      final scheme = theme.colorScheme;
      final launcher = FakeLauncher();
      TextSpan link() =>
          _spans(tester).singleWhere((s) => s.text == 'https://a.cz');

      await tester.pumpWidget(_bubble('https://a.cz', launcher, theme: theme));
      expect(link().style!.color, scheme.primary);
      expect(link().style!.decoration, TextDecoration.underline);

      await tester.pumpWidget(
        _bubble('https://a.cz', launcher, isMine: true, theme: theme),
      );
      expect(link().style!.color, scheme.onPrimaryContainer);
      expect(link().style!.decoration, TextDecoration.underline);
    });
  }

  testWidgets('the quoted reply preview stays plain', (tester) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(
      _bubble('díky', launcher, quoteText: 'viz https://a.cz'),
    );
    // The body has no link, so it is a plain Text; the quote is plain too.
    expect(_spans(tester).map((s) => s.text), ['díky']);
    expect(
      find.descendant(
        of: find.byType(LinkifiedText),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
    expect(find.text('viz https://a.cz'), findsOneWidget);
    await tester.tap(find.text('viz https://a.cz'));
    await tester.pump();
    expect(launcher.launched, isEmpty);
  });

  testWidgets('a failed launch shows a snackbar', (tester) async {
    final launcher = FakeLauncher()..result = false;
    await tester.pumpWidget(_bubble('https://a.cz', launcher));
    await tester.tapAt(_center(tester, 'https://a.cz'));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10nEn.chatLinkOpenFailed), findsOneWidget);
  });

  testWidgets('a new text is detected again', (tester) async {
    final launcher = FakeLauncher();
    await tester.pumpWidget(_bubble('https://a.cz', launcher));
    await tester.pumpWidget(_bubble('https://b.cz', launcher));
    await tester.tapAt(_center(tester, 'https://b.cz'));
    await tester.pump();
    expect(launcher.launched, [Uri.parse('https://b.cz')]);
  });

  testWidgets('selectable text (channel posts): tap opens via the override', (
    tester,
  ) async {
    final launcher = FakeLauncher();
    debugLinkLauncherOverride = launcher.call;
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(
          body: Center(
            child: LinkifiedText(
              'https://a.cz/news',
              linkColor: Colors.blue,
              selectable: true,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.byType(SelectableText));
    await tester.pump(const Duration(milliseconds: 500));
    expect(launcher.launched, [Uri.parse('https://a.cz/news')]);
  });

  test('launchExternalLink refuses other schemes', () async {
    expect(await launchExternalLink(Uri.parse('javascript:alert(1)')), isFalse);
    expect(await launchExternalLink(Uri.parse('file:///etc/passwd')), isFalse);
  });
}
