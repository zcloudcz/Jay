import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:calltype/app/app.dart';
import 'package:calltype/app/router.dart';
import 'package:calltype/core/auth/app_lock.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/core/storage/secure_storage.dart';

void main() {
  testWidgets(
    'new installation opens registration instead of fabricated conversations',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = SecureStorage();
      final api = ApiClient(baseUrl: 'http://localhost');
      final signal = SignalRClient(baseUrl: 'http://localhost', deviceId: '');
      final calls = WebRTCManager(
        signalRClient: signal,
        apiClient: api,
        myDeviceId: '',
      );
      router.go('/chats');
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider.value(value: storage),
            Provider.value(value: api),
            Provider.value(value: AppLock(secureStorage: storage)),
            ChangeNotifierProvider.value(value: signal),
            ChangeNotifierProvider.value(value: calls),
          ],
          child: const CallTypeApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      calls.dispose();
      signal.dispose();
    },
  );
}
