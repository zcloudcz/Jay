import 'dart:typed_data';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/contacts/contacts_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';

Future<ContactsController> _seeded(AppDatabase db) async {
  await db
      .into(db.contacts)
      .insert(
        ContactsCompanion.insert(
          deviceId: 'dev-1',
          userHandle: 'CT-AAAA-BBBB',
          identityKey: Uint8List(0),
          addedAt: DateTime(2026),
          displayName: const Value('Old'),
        ),
      );
  final controller = ContactsController(database: db);
  await controller.loadContacts();
  return controller;
}

void main() {
  test('renameContact trims, and blank resets to null', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final controller = await _seeded(db);

    await controller.renameContact('dev-1', '  Anna  ');
    expect(controller.contacts.single.displayName, 'Anna');

    await controller.renameContact('dev-1', '   ');
    expect(controller.contacts.single.displayName, isNull);
    expect(controller.contacts.single.userHandle, 'CT-AAAA-BBBB');
  });

  testWidgets('three dots -> Rename -> Save updates the tile', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final controller = (await tester.runAsync(() => _seeded(db)))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<ContactsController>.value(
        value: controller,
        child: localizedApp(home: const ContactsScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Old'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<void>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Anna');
    await tester.tap(find.text('Save'));
    // The drift write runs on a real isolate/timer, not the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Old'), findsNothing);
  });
}
