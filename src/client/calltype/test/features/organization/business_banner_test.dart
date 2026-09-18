import 'package:calltype/features/organization/business_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// E05 deliverable 5: banner + auditor tile rendering, and — critically —
/// that the auditor tile never offers a remove action (KB1: the client must
/// never even suggest removing the archive member).
void main() {
  testWidgets('BusinessBanner shows the organization name and no dismiss action', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(
          body: BusinessBanner(organizationName: 'Acme'),
        ),
      ),
    );

    expect(find.textContaining('Acme'), findsWidgets);
    // MaterialBanner would show a close icon only if given one explicitly;
    // guard that no such affordance was added.
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('AuditorMemberTile renders the org name and offers no remove action', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(
          body: AuditorMemberTile(organizationName: 'Acme'),
        ),
      ),
    );

    expect(find.textContaining('Acme'), findsOneWidget);
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.byIcon(Icons.remove_circle), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('BusinessBadge is a compact, non-interactive indicator', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(body: BusinessBadge(organizationName: 'Acme')),
      ),
    );
    expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);
  });
}
