import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/backup/backup_controller.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cloud backup roundtrip restores decrypted messages into a fresh database',
    () async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(source.close);
      addTearDown(target.close);
      await source
          .into(source.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: 'unverified-peer',
              userHandle: 'CT-NEW',
              identityKey: Uint8List(0),
              addedAt: DateTime.utc(2026),
            ),
          );
      await source
          .into(source.conversations)
          .insert(ConversationsCompanion.insert(id: 'chat', type: 'direct'));
      await source
          .into(source.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'm1',
              conversationId: 'chat',
              senderId: 'peer',
              body: const Value('secret message'),
              createdAt: DateTime.utc(2026),
              replyToId: const Value('orig'),
              replySenderId: const Value('peer'),
              replyPreview: const Value('quoted'),
              forwarded: const Value(true),
            ),
          );
      await source
          .into(source.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'm2',
              conversationId: 'chat',
              senderId: 'peer',
              createdAt: DateTime.utc(2026),
              deleted: const Value(true),
            ),
          );
      final dio = Dio();
      Uint8List? encrypted;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            dynamic data;
            if (options.method == 'POST') {
              final file = (options.data as FormData).files.single.value;
              encrypted = Uint8List.fromList(
                await file.finalize().expand((bytes) => bytes).toList(),
              );
              data = {'id': 1};
            } else if (options.path.endsWith('/1')) {
              data = encrypted;
            } else {
              data = [
                {'id': 1},
              ];
            }
            handler.resolve(Response(requestOptions: options, data: data));
          },
        ),
      );
      final api = ApiClient(baseUrl: 'https://example.test', dio: dio);
      final creator = BackupController(
        database: source,
        apiClient: api,
        accountId: 'account',
      );
      await creator.createBackup('roundtrip passphrase');
      expect(creator.status, BackupStatus.done);
      final restore = BackupController(
        database: target,
        apiClient: api,
        accountId: 'account',
      );
      await restore.restore('wrong passphrase');
      expect(restore.status, BackupStatus.error);
      expect(await target.select(target.messages).get(), isEmpty);
      await restore.restore('roundtrip passphrase');
      expect(restore.status, BackupStatus.done);
      expect(
        (await target.select(target.contacts).get()).single.identityKey,
        isEmpty,
      );
      final restored = {
        for (final m in await target.select(target.messages).get()) m.id: m,
      };
      expect(restored['m1']!.body, 'secret message');
      // Reply / forward / tombstone survive the encrypted round trip.
      expect(restored['m1']!.replyToId, 'orig');
      expect(restored['m1']!.replySenderId, 'peer');
      expect(restored['m1']!.replyPreview, 'quoted');
      expect(restored['m1']!.forwarded, isTrue);
      expect(restored['m2']!.deleted, isTrue);
    },
  );
  test(
    'backup uploads encrypted multipart to the account backup route',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dio = Dio();
      RequestOptions? request;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            handler.resolve(Response(requestOptions: options, data: {'id': 1}));
          },
        ),
      );
      final controller = BackupController(
        database: db,
        apiClient: ApiClient(baseUrl: 'https://example.test', dio: dio),
        accountId: 'account',
      );
      await controller.createBackup('long backup passphrase');
      expect(controller.status, BackupStatus.done);
      expect(request!.path, '/backups/account');
      expect(request!.data, isA<FormData>());
      final file = (request!.data as FormData).files.single;
      expect(file.key, 'file');
      expect(file.value.length, greaterThan(44));
    },
  );

  test(
    'restore downloads backup and reports malformed payload without writing',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dio = Dio();
      final paths = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            paths.add(options.path);
            handler.resolve(
              Response(
                requestOptions: options,
                data: options.path.endsWith('/7')
                    ? Uint8List(2)
                    : [
                        {'id': 7},
                      ],
              ),
            );
          },
        ),
      );
      final controller = BackupController(
        database: db,
        apiClient: ApiClient(baseUrl: 'https://example.test', dio: dio),
        accountId: 'account',
      );
      await controller.restore('passphrase');
      expect(paths, ['/backups/account', '/backups/account/7']);
      expect(controller.status, BackupStatus.error);
      expect(await db.select(db.messages).get(), isEmpty);
    },
  );

  test('loadBackups populates the list and deleteBackup refreshes it', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dio = Dio();
    var deleted = false;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'DELETE') deleted = true;
          final data = deleted
              ? <Map<String, dynamic>>[]
              : [
                  {'id': 1, 'sizeBytes': 100, 'createdAt': '2026-01-01'},
                ];
          handler.resolve(Response(requestOptions: options, data: data));
        },
      ),
    );
    final controller = BackupController(
      database: db,
      apiClient: ApiClient(baseUrl: 'https://example.test', dio: dio),
      accountId: 'account',
    );
    await controller.loadBackups();
    expect(controller.backups, hasLength(1));

    await controller.deleteBackup(1);
    expect(controller.backups, isEmpty);
  });

  test('quota-exceeded response maps to an actionable error message', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 409),
            ),
          );
        },
      ),
    );
    final controller = BackupController(
      database: db,
      apiClient: ApiClient(baseUrl: 'https://example.test', dio: dio),
      accountId: 'account',
    );
    await controller.createBackup('a long enough passphrase');
    expect(controller.status, BackupStatus.error);
    expect(controller.error, BackupError.limitReached);
  });
}
