import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/groups/group_create_screen.dart';

import '../../helpers/localized_app.dart';

class PendingApi extends ApiClient {
  PendingApi() : super(baseUrl: 'http://unused');
  final result = Completer<Map<String, dynamic>>();
  int requests = 0;
  @override
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> members, {
    String? organizationId,
  }) {
    requests++;
    return result.future;
  }
}

/// A minimal [HttpClientAdapter] returning a fixed enrollments list —
/// enough to drive the real [ApiClient.transport] used by the
/// `getOrganizationEnrollments` extension, without a network round trip.
class _EnrollmentsAdapter implements HttpClientAdapter {
  _EnrollmentsAdapter(this.deviceIds);
  final List<String> deviceIds;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = jsonEncode(
      deviceIds.map((id) => {'deviceId': id, 'enrolledAt': '2026-09-18T00:00:00Z'}).toList(),
    );
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _apiWithEnrollments(List<String> deviceIds) => ApiClient(
  baseUrl: 'http://unused',
  dio: Dio(BaseOptions(baseUrl: 'http://unused'))
    ..httpClientAdapter = _EnrollmentsAdapter(deviceIds),
);

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
        child: localizedApp(home: const GroupCreateScreen()),
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

  testWidgets('business group picker only offers contacts enrolled in the organization', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await tester.runAsync(() async {
      for (final id in ['enrolled-dev', 'not-enrolled-dev']) {
        await db
            .into(db.contacts)
            .insert(
              ContactsCompanion.insert(
                deviceId: id,
                userHandle: 'CT-${id.toUpperCase()}',
                identityKey: Uint8List(32),
                addedAt: DateTime.now(),
              ),
            );
      }
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          Provider<ApiClient>.value(value: _apiWithEnrollments(['enrolled-dev'])),
        ],
        child: localizedApp(
          home: const GroupCreateScreen(
            organizationId: 'org-1',
            organizationName: 'Acme',
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.textContaining('CT-ENROLLED-DEV'), findsWidgets);
    expect(find.textContaining('CT-NOT-ENROLLED-DEV'), findsNothing);
    await tester.runAsync(db.close);
  });

  testWidgets('business group picker shows an empty state when no contact is enrolled', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await tester.runAsync(() async {
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: 'not-enrolled-dev',
              userHandle: 'CT-NOT-ENROLLED-DEV',
              identityKey: Uint8List(32),
              addedAt: DateTime.now(),
            ),
          );
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          Provider<ApiClient>.value(value: _apiWithEnrollments(const [])),
        ],
        child: localizedApp(
          home: const GroupCreateScreen(
            organizationId: 'org-1',
            organizationName: 'Acme',
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.textContaining('None of your contacts are enrolled'), findsOneWidget);
    await tester.runAsync(db.close);
  });
}
