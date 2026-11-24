import 'dart:convert';

import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/privacy/block_controller.dart';
import 'package:calltype/features/privacy/data_export.dart';
import 'package:calltype/features/settings/account_deletion.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted server: answers by "METHOD path", records every request.
class FakeServer implements HttpClientAdapter {
  FakeServer([Map<String, (int, Object?)>? routes]) : routes = routes ?? {};

  final Map<String, (int, Object?)> routes;
  final requests = <RequestOptions>[];

  List<String> get calls => [
    for (final r in requests)
      '${r.method} ${r.path}${r.queryParameters.isEmpty ? '' : '?${Uri(queryParameters: r.queryParameters.map((k, v) => MapEntry(k, '$v'))).query}'}',
  ];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) =
        routes['${options.method} ${options.path}'] ?? (204, null);
    return ResponseBody.fromString(
      body == null ? '' : (body is String ? body : jsonEncode(body)),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

ApiClient apiWith(FakeServer server) => ApiClient(
  baseUrl: 'https://example.test',
  dio: Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = server,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = '11111111-1111-1111-1111-111111111111';
  const account = '22222222-2222-2222-2222-222222222222';

  group('AccountDeletionService (spec 2026-11-14-go-live A2)', () {
    late SecureStorage storage;
    late int wipes;

    AccountDeletionService service(
      FakeServer server, {
      bool companion = false,
    }) => AccountDeletionService(
      api: apiWith(server),
      storage: storage,
      isCompanion: () => companion,
      wipeLocal: () async => wipes++,
    );

    setUp(() {
      wipes = 0;
      storage = SecureStorage();
    });

    test(
      'anonymous primary deletes the identity with its companions',
      () async {
        FlutterSecureStorage.setMockInitialValues({'ct_device_id': device});
        final server = FakeServer();
        await service(server).deleteEverything();
        expect(server.calls, [
          'DELETE /devices/$device?includeCompanions=true',
        ]);
        expect(wipes, 1);
      },
    );

    test('a companion deletes only itself', () async {
      FlutterSecureStorage.setMockInitialValues({'ct_device_id': device});
      final server = FakeServer();
      await service(server, companion: true).deleteEverything();
      expect(server.calls, ['DELETE /devices/$device']);
    });

    test(
      'registered: account first with the auth key, then the device',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'ct_device_id': device,
          'ct_account_id': account,
        });
        final server = FakeServer();
        await service(server).deleteEverything(passphrase: 'correct horse');
        expect(server.calls, [
          'DELETE /accounts/$account',
          'DELETE /devices/$device?includeCompanions=true',
        ]);
        // Same derivation as registration and login (account_screen.dart).
        expect(
          (server.requests.first.data as Map)['authKey'],
          sha256.convert(utf8.encode('correct horse')).toString(),
        );
        expect(await storage.getAccountId(), isNull);
        expect(wipes, 1);
      },
    );

    test('wrong passphrase (403) deletes nothing and keeps the app', () async {
      FlutterSecureStorage.setMockInitialValues({
        'ct_device_id': device,
        'ct_account_id': account,
      });
      final server = FakeServer({'DELETE /accounts/$account': (403, null)});
      await expectLater(
        service(server).deleteEverything(passphrase: 'wrong'),
        throwsA(
          isA<AccountDeletionException>().having(
            (e) => e.error,
            'error',
            AccountDeletionError.wrongPassphrase,
          ),
        ),
      );
      expect(server.calls, ['DELETE /accounts/$account']);
      expect(await storage.getAccountId(), account);
      expect(wipes, 0);
    });

    test('organization owner (409) and auditor device are explained', () async {
      FlutterSecureStorage.setMockInitialValues({
        'ct_device_id': device,
        'ct_account_id': account,
      });
      await expectLater(
        service(
          FakeServer({
            'DELETE /accounts/$account': (
              409,
              {'code': 'account_owns_organization'},
            ),
          }),
        ).deleteEverything(passphrase: 'p'),
        throwsA(
          isA<AccountDeletionException>().having(
            (e) => e.error,
            'error',
            AccountDeletionError.ownsOrganization,
          ),
        ),
      );
      FlutterSecureStorage.setMockInitialValues({'ct_device_id': device});
      await expectLater(
        service(
          FakeServer({
            'DELETE /devices/$device': (409, {'code': 'device_is_auditor'}),
          }),
        ).deleteEverything(),
        throwsA(
          isA<AccountDeletionException>().having(
            (e) => e.error,
            'error',
            AccountDeletionError.auditor,
          ),
        ),
      );
      expect(wipes, 0);
    });

    test('a device that is already gone (404) still wipes locally', () async {
      FlutterSecureStorage.setMockInitialValues({'ct_device_id': device});
      await service(
        FakeServer({'DELETE /devices/$device': (404, null)}),
      ).deleteEverything();
      expect(wipes, 1);
    });

    test('a server error keeps everything local', () async {
      FlutterSecureStorage.setMockInitialValues({'ct_device_id': device});
      await expectLater(
        service(
          FakeServer({'DELETE /devices/$device': (500, null)}),
        ).deleteEverything(),
        throwsA(isA<AccountDeletionException>()),
      );
      expect(wipes, 0);
    });

    test('secure storage keeps only the database key', () async {
      FlutterSecureStorage.setMockInitialValues({
        'ct_db_key': 'db',
        'ct_device_id': device,
        'ct_device_secret': 'secret',
        'ct_pin_hash': 'pin',
        'ct_identity_private': 'key',
      });
      await storage.deleteAllExceptDbKey();
      expect(await const FlutterSecureStorage().readAll(), {'ct_db_key': 'db'});
    });
  });

  group('local wipe and block cache', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('wipeDatabase empties every table', () async {
      final now = DateTime.now();
      await db
          .into(db.conversations)
          .insert(ConversationsCompanion.insert(id: 'c', type: 'direct'));
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'm',
              conversationId: 'c',
              senderId: 's',
              createdAt: now,
            ),
          );
      await db
          .into(db.backupState)
          .insert(BackupStateCompanion.insert(key: 'k', value: 'v'));
      await wipeDatabase(db);
      for (final table in db.allTables) {
        expect(
          await db.select(table).get(),
          isEmpty,
          reason: table.actualTableName,
        );
      }
    });

    test(
      'BlockController mirrors the server and keeps an offline cache',
      () async {
        final server = FakeServer({
          'GET /blocks': (
            200,
            {
              'blocks': [
                {
                  'deviceId': 'AAAA',
                  'userHandle': 'CT-AAAA-AAAA',
                  'displayName': 'Eve',
                  'isBot': false,
                  'createdAt': '2026-11-14T10:00:00Z',
                },
              ],
            },
          ),
        });
        final blocks = BlockController(
          database: db,
          apiClient: apiWith(server),
        );
        await blocks.block('aaaa-companion');
        expect(server.calls, ['PUT /blocks/aaaa-companion', 'GET /blocks']);
        expect(
          blocks.isBlocked('aaaa'),
          isTrue,
          reason: 'the server answers with the identity',
        );
        expect(blocks.isBlocked('AAAA'), isTrue);

        // A fresh controller (app restart, offline) reads the cache.
        final offline = BlockController(
          database: db,
          apiClient: apiWith(FakeServer({'GET /blocks': (500, null)})),
        );
        await offline.load();
        await offline.refresh();
        expect(offline.blocked.single.userHandle, 'CT-AAAA-AAAA');
        expect(offline.blocked.single.displayName, 'Eve');

        await blocks.unblock('aaaa');
        expect(blocks.isBlocked('aaaa'), isFalse);
        await offline.load();
        expect(offline.blocked, isEmpty);
        blocks.dispose();
        offline.dispose();
      },
    );

    test(
      'block on an old server without /blocks still hides the chat',
      () async {
        final blocks = BlockController(
          database: db,
          apiClient: apiWith(FakeServer({'GET /blocks': (404, null)})),
        );
        await blocks.block('bbbb');
        expect(blocks.isBlocked('bbbb'), isTrue);
        blocks.dispose();
      },
    );
  });

  group('exportMyData (spec D13)', () {
    late List<(String, String)> saved;
    setUp(() {
      saved = [];
      exportSaver = (name, bytes) async {
        saved.add((name, utf8.decode(bytes)));
        return true;
      };
    });

    test('anonymous devices export the device scope, pretty printed', () async {
      final server = FakeServer({
        'GET /devices/$device/export': (
          200,
          '{"device":{"deviceId":"$device"}}',
        ),
      });
      final ok = await exportMyData(
        api: apiWith(server),
        deviceId: device,
        now: DateTime.utc(2026, 11, 14),
      );
      expect(ok, isTrue);
      expect(saved.single.$1, 'jay-data-export-2026-11-14.json');
      expect(saved.single.$2, contains('\n  "device": {'));
    });

    test('registered devices export the account', () async {
      final server = FakeServer({
        'GET /accounts/$account/export': (200, '{"account":{}}'),
      });
      await exportMyData(
        api: apiWith(server),
        deviceId: device,
        accountId: account,
      );
      expect(server.calls, ['GET /accounts/$account/export']);
      expect(jsonDecode(saved.single.$2), {'account': <String, dynamic>{}});
    });
  });
}
