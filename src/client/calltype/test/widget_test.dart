import 'package:flutter_test/flutter_test.dart';

import 'package:calltype/app/app.dart';

void main() {
  testWidgets('App renders initial chats route', (WidgetTester tester) async {
    // Verify the app boots and lands on the chat list screen.
    await tester.pumpWidget(const CallTypeApp());
    await tester.pumpAndSettle();

    // The ChatListScreen shows 'CallType' in the AppBar.
    expect(find.text('CallType'), findsOneWidget);
  });
}
