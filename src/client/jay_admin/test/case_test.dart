import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jay_admin/api/models.dart';
import 'package:jay_admin/l10n/app_localizations_cs.dart';
import 'package:jay_admin/l10n/app_localizations_en.dart';
import 'package:jay_admin/ui/format.dart';

import 'helpers/fake_backend.dart';

const caseUrl = '/case/$chA?postId=$postA&from=queue';

Future<void> chooseAction(WidgetTester tester, String action) async {
  await tester.tap(find.byKey(Key('action-$action')));
  await tester.pumpAndSettle();
}

Future<void> chooseDropdown(WidgetTester tester, String key, String item) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

Future<void> submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('submit-decision')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('submit-decision')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('case detail: two columns with channel, post in context, reports and history', (tester) async {
    final h = await pumpAdmin(tester, location: caseUrl);
    final req = h.backend.where('GET', '/admin/subjects/$chA').single;
    expect(req.url.queryParameters['postId'], postA);

    expect(find.text('Cheap Deals'), findsOneWidget);
    expect(find.text('Owner CT-OWNR-0001'), findsOneWidget);
    expect(find.text('Earlier post'), findsOneWidget);
    expect(find.text('Later post by bot'), findsOneWidget);
    expect(find.text('BOT'), findsOneWidget);
    expect(find.byKey(const Key('reported-post')), findsOneWidget);
    expect(find.text('Reports (2)'), findsOneWidget);
    expect(find.text('Fraud: asks for bank password'), findsOneWidget);
    expect(find.text("Reporter's e-mail: reporter@example.com"), findsOneWidget);
    expect(find.text('good faith confirmed'), findsOneWidget);
    expect(find.textContaining('Phishing for bank credentials.'), findsOneWidget);

    // Wide layout: context and panel side by side.
    final ctx = tester.getTopLeft(find.text('Cheap Deals'));
    final panel = tester.getTopLeft(find.text('Decision'));
    expect(panel.dx, greaterThan(ctx.dx + 400));
  });

  testWidgets('reported image stays blurred until clicked', (tester) async {
    final h = await pumpAdmin(tester, location: caseUrl);
    final att = h.backend.requests.where((r) => r.url.path.contains('/attachments/')).single;
    expect(att.url.path, '/admin/channels/$chA/attachments/abc.png');
    expect(att.headers['Authorization'], 'Bearer op-token');

    expect(find.byKey(const Key('image-blurred')), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.text('Hidden image. Click to show it.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('image-blurred')));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byKey(const Key('image-revealed')), findsOneWidget);
  });

  testWidgets('decision panel validation: action, ground, rule, legal ground, explanation, days', (tester) async {
    final h = await pumpAdmin(tester, location: caseUrl);

    await submit(tester);
    expect(find.byKey(const Key('action-required')), findsOneWidget);

    await chooseAction(tester, 'remove_post');
    await submit(tester);
    expect(find.text('Choose the ground.'), findsOneWidget);
    expect(find.text('Write the explanation (1 to 2000 characters).'), findsOneWidget);

    await chooseDropdown(tester, 'ground', 'Channel rule (K1 to K10)');
    await submit(tester);
    expect(find.text('Choose the rule.'), findsOneWidget);

    await chooseDropdown(tester, 'ground', 'Illegal content (law)');
    expect(find.text('Choose the rule.'), findsNothing);
    await submit(tester);
    expect(find.text('State the legal ground (1 to 300 characters).'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('legal-ground')), '   ');
    await tester.enterText(find.byKey(const Key('explanation')), '  ');
    await tester.pumpAndSettle();
    expect(find.text('State the legal ground (1 to 300 characters).'), findsOneWidget);
    expect(find.text('Write the explanation (1 to 2000 characters).'), findsOneWidget);

    await chooseAction(tester, 'suspend_channel');
    await tester.enterText(find.byKey(const Key('suspend-days')), '0');
    await tester.pumpAndSettle();
    expect(find.text('Enter 1 to 365 days.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('suspend-days')), '366');
    await tester.pumpAndSettle();
    expect(find.text('Enter 1 to 365 days.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('suspend-days')), '30');
    await tester.pumpAndSettle();
    expect(find.text('Enter 1 to 365 days.'), findsNothing);

    // Still invalid (no legal ground, no explanation): nothing was sent.
    await submit(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(h.backend.where('POST', '/admin/decisions'), isEmpty);
  });

  testWidgets('remove post by rule: preview shows the statement, confirm sends the contract body, next case opens', (tester) async {
    final h = await pumpAdmin(tester, location: caseUrl);
    await chooseAction(tester, 'remove_post');
    await chooseDropdown(tester, 'ground', 'Channel rule (K1 to K10)');
    await chooseDropdown(tester, 'rule', 'K4 Fraud and deception');
    await tester.enterText(find.byKey(const Key('explanation')), 'The post asks followers for bank passwords.');
    await tester.pumpAndSettle();

    final preview = tester.widget<SelectableText>(
      find.descendant(of: find.byKey(const Key('statement-preview')), matching: find.byType(SelectableText)),
    ).data!;
    expect(preview, contains('We removed a post from your channel Cheap Deals (CH-AAAA-1111).'));
    expect(preview, contains('Reason: rule K4 Fraud and deception of the channel rules (https://jay.zcloud.cz/legal/channels-en.html#K4).'));
    expect(preview, contains('Explanation: The post asks followers for bank passwords.'));
    expect(preview, contains('The decision followed a report from users.'));
    expect(preview, contains('Disagree? Write to martin@zcloud.cz within 6 months.'));
    expect(find.text('Reporters will see: action taken'), findsOneWidget);

    await submit(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const Key('confirm-preview')), findsOneWidget);
    expect(find.byKey(const Key('confirm-handle')), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-ok')));
    await tester.pumpAndSettle();

    final body = jsonDecode(h.backend.where('POST', '/admin/decisions').single.body) as Map;
    expect(body, {
      'channelId': chA,
      'postId': postA,
      'action': 'remove_post',
      'ground': 'terms',
      'rule': 'K4',
      'explanation': 'The post asks followers for bank passwords.',
    });
    // Next open case (the other subject of the fake queue) opens directly.
    expect(currentLocation(tester), '/case/$chB?from=queue');
    expect(find.text('Decision saved. Next case.'), findsOneWidget);
  });

  testWidgets('cancel in the confirmation sends nothing', (tester) async {
    final h = await pumpAdmin(tester, location: caseUrl);
    await chooseAction(tester, 'dismiss');
    await tester.enterText(find.byKey(const Key('explanation')), 'Not a violation.');
    await tester.pumpAndSettle();
    expect(find.text('Nothing is sent to the owner.'), findsWidgets);
    expect(find.text('Reporters will see: dismissed'), findsOneWidget);
    await submit(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.backend.where('POST', '/admin/decisions'), isEmpty);
  });

  testWidgets('terminate requires typing the channel handle', (tester) async {
    final h = await pumpAdmin(tester, location: caseUrl);
    await chooseAction(tester, 'terminate_channel');
    await chooseDropdown(tester, 'ground', 'Illegal content (law)');
    await tester.enterText(find.byKey(const Key('legal-ground')), 'Criminal Code s. 209 (fraud)');
    await tester.enterText(find.byKey(const Key('explanation')), 'Channel exists only to phish.');
    await tester.pumpAndSettle();
    await submit(tester);

    FilledButton ok() => tester.widget<FilledButton>(find.byKey(const Key('confirm-ok')));
    expect(find.text('Type the channel handle CH-AAAA-1111 to confirm'), findsOneWidget);
    expect(ok().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('confirm-handle')), 'CH-AAAA-111');
    await tester.pump();
    expect(ok().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('confirm-handle')), 'CH-AAAA-1111');
    await tester.pump();
    expect(ok().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('confirm-ok')));
    await tester.pumpAndSettle();

    final body = jsonDecode(h.backend.where('POST', '/admin/decisions').single.body) as Map;
    expect(body, {
      'channelId': chA,
      'action': 'terminate_channel',
      'ground': 'illegal',
      'legalGround': 'Criminal Code s. 209 (fraud)',
      'explanation': 'Channel exists only to phish.',
    });
  });

  testWidgets('server refusal is shown in the panel', (tester) async {
    final backend = FakeBackend()..overrides['POST /admin/decisions'] = (_) => FakeBackend.error(409, 'already_removed');
    await pumpAdmin(tester, backend: backend, location: caseUrl);
    await chooseAction(tester, 'remove_post');
    await chooseDropdown(tester, 'ground', 'Channel rule (K1 to K10)');
    await chooseDropdown(tester, 'rule', 'K5 Spam and manipulation');
    await tester.enterText(find.byKey(const Key('explanation')), 'Spam.');
    await submit(tester);
    await tester.tap(find.byKey(const Key('confirm-ok')));
    await tester.pumpAndSettle();
    expect(find.text('The post has already been removed.'), findsOneWidget);
  });

  group('statementPreview', () {
    final now = DateTime.utc(2026, 11, 5, 12);
    test('suspension states length and end date (en)', () {
      final s = statementPreview(
        AppLocalizationsEn(),
        'en',
        const StatementDraft(
          action: 'suspend_channel',
          channelLabel: 'X (CH-1)',
          ground: 'terms',
          rule: 'K5',
          explanation: 'Same ad every minute.',
          suspendDays: 30,
          basedOnReports: true,
        ),
        now: now,
      )!;
      expect(s.split('\n'), [
        'We suspended your channel X (CH-1) for 30 days, until 12/5/2026. Followers cannot see it and nobody can post in it.',
        'Reason: rule K5 Spam and manipulation of the channel rules (https://jay.zcloud.cz/legal/channels-en.html#K5).',
        'Explanation: Same ad every minute.',
        'The decision followed a report from users.',
        'It was made by a person, not automatically.',
        'Disagree? Write to martin@zcloud.cz within 6 months.',
      ]);
    });

    test('illegal ground in Czech links nothing and cites the law; own initiative', () {
      final s = statementPreview(
        AppLocalizationsCs(),
        'cs',
        const StatementDraft(
          action: 'terminate_channel',
          channelLabel: 'X (CH-1)',
          ground: 'illegal',
          legalGround: 'tr. zákoník § 209',
          explanation: 'Podvod.',
        ),
        now: now,
      )!;
      expect(s, contains('Zrušili jsme váš kanál X (CH-1).'));
      expect(s, contains('Důvod: nezákonný obsah (tr. zákoník § 209).'));
      expect(s, contains('Rozhodli jsme z vlastní iniciativy.'));
      expect(s, contains('Nesouhlasíte? Napište do 6 měsíců na martin@zcloud.cz.'));
    });

    test('dismiss produces no statement; rule URLs use the cs page for cs', () {
      expect(statementPreview(AppLocalizationsEn(), 'en', const StatementDraft(action: 'dismiss', channelLabel: 'x')), isNull);
      expect(Rules.url('K10', 'cs').toString(), 'https://jay.zcloud.cz/legal/channels-cs.html#K10');
      expect(Rules.url('K1', 'de').toString(), 'https://jay.zcloud.cz/legal/channels-en.html#K1');
      expect(Rules.ids, hasLength(10));
    });
  });
}
