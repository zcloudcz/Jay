import 'package:flutter_test/flutter_test.dart';

import 'package:zmessanger/app/app.dart';

void main() {
  testWidgets('App renders initial chats route', (WidgetTester tester) async {
    // Verify the app boots and lands on the chats placeholder screen.
    await tester.pumpWidget(const ZMessangerApp());
    await tester.pumpAndSettle();

    // The placeholder for /chats displays 'Chats' in both AppBar and body.
    expect(find.text('Chats'), findsWidgets);
  });
}
