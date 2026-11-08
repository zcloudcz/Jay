import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/contacts/contacts_screen.dart';

import '../../helpers/localized_app.dart';

class EmptyContacts extends ContactsController {
  EmptyContacts(AppDatabase db) : super(database: db);
  @override
  Future<void> loadContacts() async {}
}

void main() {
  testWidgets(
    'Windows offers paste invite without unsupported camera scanner',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final controller = EmptyContacts(db);
      addTearDown(() {
        controller.dispose();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<ContactsController>.value(
          value: controller,
          child: localizedApp(home: const ContactsScreen()),
        ),
      );
      await tester.pump();
      expect(find.byTooltip('Scan QR code'), findsNothing);
      await tester.tap(find.byTooltip('Paste invite'));
      await tester.pumpAndSettle();
      expect(find.text('Handle or invite'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
