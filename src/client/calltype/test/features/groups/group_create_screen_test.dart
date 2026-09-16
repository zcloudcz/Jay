import 'dart:async';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/groups/group_create_screen.dart';

class PendingApi extends ApiClient {
  PendingApi() : super(baseUrl: 'http://unused');
  final result = Completer<Map<String, dynamic>>();
  int requests = 0;
  @override
  Future<Map<String, dynamic>> createGroup(String name, List<String> members) {
    requests++;
    return result.future;
  }
}

void main() {
  testWidgets('double create while pending issues only one server request', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final api = PendingApi();
    await tester.runAsync(() async {
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: 'bob',
              userHandle: 'CT-BOB',
              identityKey: Uint8List(32),
              addedAt: DateTime.now(),
            ),
          );
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          Provider<ApiClient>.value(value: api),
        ],
        child: const MaterialApp(home: GroupCreateScreen()),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Team');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.tap(find.text('Create'));
    expect(api.requests, 1);
    await tester.pumpWidget(const SizedBox());
    api.result.completeError(StateError('offline'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.runAsync(db.close);
  });
}
