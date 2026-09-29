import 'package:calltype/shared/widgets/app_version_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../helpers/localized_app.dart';

// P2: the settings page shows the real build name + number (the same pair the
// release manifest records, acceptance R-04) instead of a hard-coded '1.0.0'.
void main() {
  Future<PackageInfo> info() async => PackageInfo(
    appName: 'Jay',
    packageName: 'cz.zcloud.jay',
    version: '1.2.0',
    buildNumber: '142',
  );

  testWidgets('shows version and build number from the bundle', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Jay',
      packageName: 'cz.zcloud.jay',
      version: '1.2.0',
      buildNumber: '142',
      buildSignature: '',
    );
    await tester.pumpWidget(
      localizedApp(home: const Scaffold(body: AppVersionLabel())),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10nEn.settingsVersion('1.2.0 (142)')), findsOneWidget);
  });

  testWidgets('renders nothing and does not throw when loading fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: AppVersionLabel(
            loader: () => Future<PackageInfo>.error(StateError('no bundle')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Text), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders nothing while the bundle info is still loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: AppVersionLabel(
            loader: () => Future.delayed(const Duration(seconds: 1), info),
          ),
        ),
      ),
    );
    expect(find.byType(Text), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.settingsVersion('1.2.0 (142)')), findsOneWidget);
  });

  testWidgets('short commit SHA as tooltip when the build carries one', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: AppVersionLabel(
            loader: info,
            commitSha: '0123456789abcdef0123456789abcdef01234567',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('0123456'), findsOneWidget);
  });

  testWidgets('no tooltip in dev builds without JAY_COMMIT_SHA', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: AppVersionLabel(loader: info, commitSha: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('localized: Czech and Arabic (RTL) render the label', (
    tester,
  ) async {
    for (final locale in const [Locale('cs'), Locale('ar')]) {
      await tester.pumpWidget(
        localizedApp(
          locale: locale,
          home: Scaffold(body: AppVersionLabel(loader: info)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1.2.0 (142)'), findsOneWidget);
    }
  });
}
