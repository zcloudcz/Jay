import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/features/organization/organization_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// N03d: [OrganizationController]'s `withMfa` wiring — an admin call that
/// answers `mfa_required` retries once after a successful prompt, locks
/// (no second request) on a cancelled prompt, and never even asks a plain
/// member. Needs a real [HttpClientAdapter] fake, same reasoning as
/// `mfa_controller_test.dart`: the request-interceptor-reject fake used
/// elsewhere in this test suite short-circuits before `_StepUpInterceptor`'s
/// `onError` (which does the 403→`MfaRequiredException` conversion) ever runs.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  static ResponseBody json(int status, String body) => ResponseBody.fromString(
    body,
    status,
    headers: {'content-type': ['application/json']},
  );
}

void main() {
  test(
    'setAuditorDevice: mfa_required is retried once after the prompt verifies, and succeeds',
    () async {
      var setAuditorCalls = 0;
      var promptCalls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) {
            if (options.path.contains('/auditor')) {
              setAuditorCalls++;
              // First call is rejected; the retry (after the prompt
              // "verified") succeeds.
              return setAuditorCalls == 1
                  ? _FakeAdapter.json(403, '{"error":"x","code":"mfa_required"}')
                  : _FakeAdapter.json(204, '');
            }
            if (options.path == '/orgs' && options.method == 'POST') {
              return _FakeAdapter.json(200, '{"organizationId":"org1","name":"Acme"}');
            }
            if (options.path == '/orgs/mine') {
              return _FakeAdapter.json(
                200,
                '[{"organizationId":"org1","name":"Acme","role":"owner","archiveLevel":"metadata"}]',
              );
            }
            // GET /orgs/org1 — member list, both at createOrganization and
            // after setAuditorDevice's re-read.
            return _FakeAdapter.json(
              200,
              '{"organizationId":"org1","name":"Acme","members":[]}',
            );
          }),
      );
      final controller = OrganizationController(apiClient: api)
        ..promptForMfa = () async {
          promptCalls++;
          return true;
        };
      // setAuditorDevice needs `organization` set first, same as the real
      // screen (only reachable once an organization is loaded).
      await controller.createOrganization('Acme');

      await controller.setAuditorDevice('device-x');

      expect(setAuditorCalls, 2, reason: 'one failed call, one retry');
      expect(promptCalls, 1);
      expect(controller.locked, isFalse);
      expect(controller.errorCode, isNull);
    },
  );

  test(
    'setAuditorDevice: a cancelled prompt locks the screen and never retries',
    () async {
      var setAuditorCalls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) {
            if (options.path.contains('/auditor')) {
              setAuditorCalls++;
              return _FakeAdapter.json(403, '{"error":"x","code":"mfa_required"}');
            }
            if (options.path == '/orgs' && options.method == 'POST') {
              return _FakeAdapter.json(200, '{"organizationId":"org1","name":"Acme"}');
            }
            return _FakeAdapter.json(
              200,
              '{"organizationId":"org1","name":"Acme","members":[]}',
            );
          }),
      );
      final controller = OrganizationController(apiClient: api)
        ..promptForMfa = () async => false;
      await controller.createOrganization('Acme');

      await controller.setAuditorDevice('device-x');

      expect(setAuditorCalls, 1, reason: 'a cancelled prompt must not retry');
      expect(controller.locked, isTrue);
      expect(controller.errorCode, isNull, reason: 'locked, not a raw error');
    },
  );

  test(
    'a plain member never sees a prompt: load() skips the admin-only audit count',
    () async {
      var promptCalls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) {
            if (options.path == '/orgs/mine') {
              return _FakeAdapter.json(
                200,
                '[{"organizationId":"org1","name":"Acme","role":"Member","archiveLevel":"Metadata"}]',
              );
            }
            // GET /orgs/{id} for members — never the audit-count endpoint,
            // since this member isn't an admin.
            return _FakeAdapter.json(
              200,
              '{"organizationId":"org1","name":"Acme","members":[]}',
            );
          }),
      );
      final controller = OrganizationController(apiClient: api)
        ..promptForMfa = () async {
          promptCalls++;
          return true;
        };

      await controller.load();

      expect(promptCalls, 0);
      expect(controller.locked, isFalse);
      expect(controller.errorCode, isNull);
    },
  );
}
