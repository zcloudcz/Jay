import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/organization/emergency/emergency_controller.dart';
import 'package:calltype_core/network/emergency_api.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// E07 deliverable 5 (widget/controller tests): enroll with a faked API, kit
/// issue shows codes once, and the enroll error mapping. Same fake-Dio
/// interceptor pattern as organization_controller_test.dart — the emergency
/// API is a Dio extension, so it can't be mocked by subclassing ApiClient.
void main() {
  ApiClient apiWith(
    Response<dynamic> Function(RequestOptions options) respond,
  ) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          try {
            handler.resolve(respond(options));
          } on DioException catch (e) {
            handler.reject(e);
          }
        },
      ),
    );
    return ApiClient(baseUrl: 'https://example.test', dio: dio);
  }

  group('EmergencyEnrollController', () {
    test('enroll succeeds, records the joined organization id and creates the local conversation', () async {
      final api = apiWith((options) {
        expect(options.path, '/orgs/emergency/enroll');
        expect(options.data, {'code': 'ABCD-1234'});
        return Response(
          requestOptions: options,
          data: {'organizationId': 'org-1', 'groupId': 'group-1'},
        );
      });
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final controller = EmergencyEnrollController(apiClient: api, database: db);

      await controller.enroll('ABCD-1234', fallbackTitle: 'Emergency channel');

      expect(controller.errorCode, isNull);
      expect(controller.enrolledOrganizationId, 'org-1');
      expect(controller.enrolledConversationId, 'group-1');
      final row = await (db.select(db.conversations)..where((c) => c.id.equals('group-1'))).getSingle();
      expect(row.type, 'group');
      expect(row.title, 'Emergency channel');
    });

    test('a null groupId (no auditor configured yet) leaves enrolledConversationId unset', () async {
      final api = apiWith((options) => Response(
        requestOptions: options,
        data: {'organizationId': 'org-1', 'groupId': null},
      ));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final controller = EmergencyEnrollController(apiClient: api, database: db);

      await controller.enroll('ABCD-1234', fallbackTitle: 'Emergency channel');

      expect(controller.enrolledOrganizationId, 'org-1');
      expect(controller.enrolledConversationId, isNull);
    });

    test('a used code maps 410 to emergency_code_used', () async {
      final api = apiWith(
        (options) => throw DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 410,
            data: {'code': 'emergency_code_used'},
          ),
        ),
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final controller = EmergencyEnrollController(apiClient: api, database: db);

      await controller.enroll('STALE-CODE', fallbackTitle: 'Emergency channel');

      expect(controller.errorCode, 'emergency_code_used');
      expect(controller.enrolledOrganizationId, isNull);
    });

    test('a revoked kit maps 410 to kit_revoked', () async {
      final api = apiWith(
        (options) => throw DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 410,
            data: {'code': 'kit_revoked'},
          ),
        ),
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final controller = EmergencyEnrollController(apiClient: api, database: db);

      await controller.enroll('REVOKED-CODE', fallbackTitle: 'Emergency channel');

      expect(controller.errorCode, 'kit_revoked');
    });
  });

  group('EmergencyController', () {
    test('issueKit stores the plaintext codes once, then clearJustIssuedKit discards them', () async {
      final api = apiWith((options) {
        if (options.method == 'POST' && options.path.endsWith('/emergency/kits')) {
          expect(options.data, {'label': 'HQ team', 'count': 3});
          return Response(
            requestOptions: options,
            data: {
              'kitId': 'kit-1',
              'label': 'HQ team',
              'issuedAt': '2026-09-18T00:00:00Z',
              'recoveryCode': 'RECOVERY-CODE',
              'codes': ['CODE-1', 'CODE-2', 'CODE-3'],
              'printable': 'printable text',
            },
          );
        }
        // Follow-up GET /emergency/kits and /emergency/drills after issueKit.
        return Response(
          requestOptions: options,
          data: options.path.endsWith('/emergency/kits')
              ? [
                  {
                    'kitId': 'kit-1', 'label': 'HQ team', 'issuedAt': '2026-09-18T00:00:00Z',
                    'revokedAt': null, 'codesTotal': 3, 'codesRemaining': 3,
                  },
                ]
              : <dynamic>[],
        );
      });
      final controller = EmergencyController(apiClient: api, organizationId: 'org-1');

      await controller.issueKit('HQ team', 3);

      expect(controller.errorCode, isNull);
      expect(controller.justIssuedKit?.codes, ['CODE-1', 'CODE-2', 'CODE-3']);
      expect(controller.kits, hasLength(1));

      controller.clearJustIssuedKit();

      expect(controller.justIssuedKit, isNull);
    });

    test('auditor_not_configured (409) surfaces its code when issuing a kit', () async {
      final api = apiWith(
        (options) => throw DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 409,
            data: {'code': 'auditor_not_configured'},
          ),
        ),
      );
      final controller = EmergencyController(apiClient: api, organizationId: 'org-1');

      await controller.issueKit('HQ team', 3);

      expect(controller.errorCode, 'auditor_not_configured');
      expect(controller.justIssuedKit, isNull);
    });

    test('completeDrill (confirm flow) calls the endpoint and refreshes the drill list', () async {
      var confirmedCall = false;
      final api = apiWith((options) {
        if (options.path.contains('/complete')) {
          confirmedCall = true;
          return Response(requestOptions: options, statusCode: 204);
        }
        return Response(
          requestOptions: options,
          data: [
            {
              'drillId': 1, 'startedAt': '2026-09-18T00:00:00Z',
              'completedAt': '2026-09-18T00:05:00Z',
              'confirmedMemberCount': 4, 'responseTimeSeconds': 12.5,
            },
          ],
        );
      });
      final controller = EmergencyController(apiClient: api, organizationId: 'org-1');

      await controller.completeDrill(1);

      expect(confirmedCall, isTrue);
      expect(controller.errorCode, isNull);
      expect(controller.drills.single.confirmedMemberCount, 4);
    });

    test('a member device confirming a drill hits the confirm endpoint (EmergencyDrillOverlay path)', () async {
      var confirmCalled = false;
      final api = apiWith((options) {
        expect(options.path, '/orgs/org-1/emergency/drills/7/confirm');
        confirmCalled = true;
        return Response(requestOptions: options, statusCode: 204);
      });

      await api.confirmEmergencyDrill('org-1', 7);

      expect(confirmCalled, isTrue);
    });
  });
}
