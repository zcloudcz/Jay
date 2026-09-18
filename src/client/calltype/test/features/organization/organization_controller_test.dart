import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/features/organization/organization_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// E05 deliverable 5: enroll flow with a faked API, plus the 503/409/410
/// error-code mapping the Organization screen relies on to show the right
/// message. The fake is a Dio interceptor (same pattern as
/// backup_controller_test.dart) — ApiClient's business-mode methods are an
/// extension, so they can't be overridden by subclassing.
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

  test('enroll succeeds and loads the joined organization', () async {
    final api = apiWith((options) {
      if (options.path == '/orgs/enroll') {
        return Response(requestOptions: options, data: {'organizationId': 'org1'});
      }
      // Real contract: the caller's role only comes from GET /orgs/mine.
      return Response(
        requestOptions: options,
        data: [
          {
            'organizationId': 'org1',
            'name': 'Acme',
            'role': 'Member',
            'archiveLevel': 'Metadata',
          },
        ],
      );
    });
    final controller = OrganizationController(apiClient: api);

    await controller.enroll('CODE-1234');

    expect(controller.errorCode, isNull);
    expect(controller.organization?.name, 'Acme');
    expect(controller.organization?.organizationId, 'org1');
  });

  test('enroll with an expired/used invite maps 410 to invite_invalid', () async {
    final api = apiWith(
      (options) => throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 410),
      ),
    );
    final controller = OrganizationController(apiClient: api);

    await controller.enroll('STALE-CODE');

    expect(controller.errorCode, 'invite_invalid');
    expect(controller.organization, isNull);
  });

  test('business mode disabled (503) is surfaced distinctly from other errors', () async {
    final api = apiWith(
      (options) => throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 503),
      ),
    );
    final controller = OrganizationController(apiClient: api);

    await controller.load();

    expect(controller.errorCode, 'business_mode_disabled');
  });

  test('removing the last admin (409 last_admin) is surfaced with its code', () async {
    final api = apiWith((options) {
      if (options.method == 'DELETE') {
        throw DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 409,
            data: {'code': 'last_admin'},
          ),
        );
      }
      if (options.path == '/orgs/mine') {
        return Response(
          requestOptions: options,
          data: [
            {
              'organizationId': 'org1',
              'name': 'Acme',
              'role': 'owner',
              'archiveLevel': 'metadata',
            },
          ],
        );
      }
      // GET /orgs/org1 (members live inside it) and .../audit/records/count
      return Response(
        requestOptions: options,
        data: options.path == '/orgs/org1'
            ? {'organizationId': 'org1', 'name': 'Acme', 'members': <dynamic>[]}
            : {'count': 0},
      );
    });
    final controller = OrganizationController(apiClient: api);
    await controller.load();
    expect(controller.errorCode, isNull);

    await controller.revokeEnrollment('device-x');

    expect(controller.errorCode, 'last_admin');
  });
}
