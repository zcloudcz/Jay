import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_backend.dart';

void main() {
  testWidgets('overview shows the summary counts', (tester) async {
    await pumpAdmin(tester);
    expect(find.descendant(of: find.byKey(const Key('metric-open-reports')), matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('metric-open-subjects')), matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('metric-oldest')), matching: find.text('3 hours')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('metric-suspended')), matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('metric-decisions')), matching: find.text('4')), findsOneWidget);
  });

  testWidgets('queue rows say why each subject is there; tabs carry counts', (tester) async {
    final h = await pumpAdmin(tester, location: '/queue?status=open');
    final req = h.backend.where('GET', '/admin/reports').single;
    expect(req.url.queryParameters['status'], 'open');

    expect(find.text('Open (2)'), findsOneWidget);
    expect(find.text('Resolved (9)'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);

    // Row 1: post subject.
    expect(find.text('Cheap Deals'), findsOneWidget);
    expect(find.text('CH-AAAA-1111'), findsOneWidget);
    expect(find.text('3 reports'), findsOneWidget);
    expect(find.text('Illegal content 1'), findsOneWidget);
    expect(find.text('Rule violation 2'), findsOneWidget);
    expect(find.text('"This is a phishing scam asking for passwords"'), findsOneWidget);
    expect(find.text('1234 followers'), findsNWidgets(2));
    expect(find.text('waiting 3 hours'), findsOneWidget);
    expect(find.text('1 prior action'), findsOneWidget);
    // The queue never fetches images: only a placeholder.
    expect(find.text('Image (hidden)'), findsOneWidget);
    expect(h.backend.requests.where((r) => r.url.path.contains('/attachments/')), isEmpty);

    // Row 2: channel subject.
    expect(find.text('Ad Blaster'), findsOneWidget);
    expect(find.text('1 report'), findsOneWidget);
    expect(find.text('Spam 1'), findsOneWidget);
    expect(find.text('waiting 2 days'), findsOneWidget);
    expect(find.text('no prior actions'), findsOneWidget);
  });

  testWidgets('filters go into the URL and the API query', (tester) async {
    final h = await pumpAdmin(tester, location: '/queue?status=open');

    await tester.tap(find.byKey(const Key('filter-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam').last);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/queue?status=open&category=spam');
    expect(h.backend.requests.last.url.queryParameters['category'], 'spam');
    expect(find.text('Ad Blaster'), findsOneWidget);
    expect(find.text('Cheap Deals'), findsNothing);

    await tester.tap(find.byKey(const Key('filter-subject')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post').last);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/queue?status=open&category=spam&subjectType=post');
    expect(h.backend.requests.last.url.queryParameters['subjectType'], 'post');
    expect(find.text('Nothing here.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab-resolved')));
    await tester.pumpAndSettle();
    expect(h.backend.requests.last.url.queryParameters['status'], 'resolved');
    expect(currentLocation(tester), startsWith('/queue?status=resolved'));
  });

  testWidgets('keyboard: j moves down, k up, Enter opens the case', (tester) async {
    await pumpAdmin(tester, location: '/queue?status=open');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ); // clamps at the last row
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/case/$chB?from=queue');

    await tester.tap(find.text('Back to the queue'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/case/$chA?postId=$postA&from=queue');
  });

  testWidgets('channel search lists status and opens the channel', (tester) async {
    final h = await pumpAdmin(tester, location: '/channels');
    await tester.enterText(find.byKey(const Key('channels-query')), 'CH-BBBB');
    await tester.tap(find.byKey(const Key('channels-search')));
    await tester.pumpAndSettle();
    expect(h.backend.where('GET', '/admin/channels').single.url.queryParameters['q'], 'CH-BBBB');
    expect(find.text('suspended'), findsOneWidget);
    expect(find.text('active'), findsOneWidget);
    await tester.tap(find.text('Ad Blaster'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/case/$chB');
    // Suspended channel: restore is offered, suspend is not.
    expect(find.byKey(const Key('action-restore_channel')), findsOneWidget);
    expect(find.byKey(const Key('action-suspend_channel')), findsNothing);
  });
}
