import 'package:flutter_test/flutter_test.dart';

import 'package:zmessanger/app/app.dart';

void main() {
  testWidgets('App renders initial chats route', (WidgetTester tester) async {
    // Verify the app boots and lands on the chat list screen.
    await tester.pumpWidget(const ZMessangerApp());
    await tester.pumpAndSettle();

    // The ChatListScreen shows 'ZMessanger' in the AppBar.
    expect(find.text('ZMessanger'), findsOneWidget);
  });
}
