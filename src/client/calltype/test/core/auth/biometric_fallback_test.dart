import 'package:calltype/core/auth/app_lock.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/settings/app_lock_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';

class UnsupportedBiometrics extends LocalAuthentication {
  @override
  Future<bool> get canCheckBiometrics async =>
      throw MissingPluginException('Biometrics unavailable');
}

void main() {
  testWidgets('PIN settings load when biometrics have no platform plugin', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final lock = AppLock(
      secureStorage: SecureStorage(),
      localAuth: UnsupportedBiometrics(),
    );
    await tester.pumpWidget(
      Provider<AppLock>.value(
        value: lock,
        child: localizedApp(home: const AppLockSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('PIN Lock'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Biometric Unlock'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
