import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:calltype_core/auth/auth_service.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:jay_archiver/jay_archiver.dart';

/// `jay_archiver provision --api <url> --org <orgId> --state <dir> --admin-token <jwt>`
/// `jay_archiver run --api <url> --org <orgId> --state <dir>`
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: jay_archiver <provision|run> --api <url> --org <orgId> --state <dir> [--admin-token <jwt>]');
    exit(64);
  }
  final command = args.first;
  final opts = _parseOptions(args.skip(1));

  switch (command) {
    case 'provision':
      await _provision(opts);
    case 'run':
      await _run(opts);
    default:
      stderr.writeln('Unknown command "$command". Use "provision" or "run".');
      exit(64);
  }
}

Map<String, String> _parseOptions(Iterable<String> args) {
  final map = <String, String>{};
  final list = args.toList();
  for (var i = 0; i < list.length - 1; i++) {
    if (list[i].startsWith('--')) map[list[i].substring(2)] = list[i + 1];
  }
  return map;
}

String _require(Map<String, String> opts, String key) =>
    opts[key] ?? (throw ArgumentError('Missing required --$key'));

/// Registers a fresh bot device (isBot: true) and makes it the organization's
/// auditor. Prints only the device id — the store directory holds the keys.
Future<void> _provision(Map<String, String> opts) async {
  final apiBaseUrl = _require(opts, 'api');
  final orgId = _require(opts, 'org');
  final statePath = _require(opts, 'state');
  final adminToken = _require(opts, 'admin-token');

  // CallTypeBot.start() already does exactly what an auditor device needs at
  // provisioning time: register with isBot: true and persist keys/secret in
  // EncryptedFileStore. It is never connected here (no onMessage call), so
  // this is a one-shot registration, not a running bot.
  final bot = await CallTypeBot.start(
    apiBaseUrl: apiBaseUrl,
    storePath: statePath,
    displayName: 'Jay Archiver',
    log: (_) {}, // registration confirmation would leak the handle/deviceId twice; caller reads stdout below
  );

  // PUT /orgs/{orgId}/auditor is owned by E01 — called here with the
  // caller-supplied admin JWT, never this device's own token (a fresh
  // auditor device has no organization membership of its own to authorize with).
  final admin = Dio(BaseOptions(baseUrl: apiBaseUrl, headers: {'Authorization': 'Bearer $adminToken'}));
  await admin.put('/orgs/$orgId/auditor', data: {'deviceId': bot.deviceId});

  await bot.close();
  stdout.writeln(bot.deviceId);
}

/// Connects as the already-provisioned auditor device and archives forever.
Future<void> _run(Map<String, String> opts) async {
  final apiBaseUrl = _require(opts, 'api');
  final orgId = _require(opts, 'org');
  final statePath = _require(opts, 'state');

  final key = EncryptedFileStore.parseKey(Platform.environment['BOT_STORE_KEY']);
  final store = await EncryptedFileStore.open(statePath, key);
  final deviceId = await store.getDeviceId();
  if (deviceId == null) {
    stderr.writeln('No device in "$statePath" — run "provision" first.');
    exit(1);
  }

  final db = AppDatabase(NativeDatabase(File('$statePath.sqlite')));
  final keys = KeyManager(secureStorage: store);
  final auth = AuthService(secureStorage: store, baseUrl: apiBaseUrl);
  final api = ApiClient(baseUrl: apiBaseUrl, authService: auth);
  final sessions = SessionManager(database: db, keyManager: keys);
  final signalR = SignalRClient(
    baseUrl: apiBaseUrl,
    deviceId: deviceId,
    authService: auth,
    transportFactory: WebSocketHubTransport.new,
  );

  final source = SignalGroupMessageSource(
    signalR: signalR,
    sessions: sessions,
    log: stderr.writeln,
  );
  final archiver = Archiver(
    source: source,
    api: api.transport,
    organizationId: orgId,
    log: stderr.writeln,
  );

  await signalR.connect();
  await signalR.requestPendingMessages();
  stdout.writeln('Archiving organization $orgId as device $deviceId...');

  try {
    await archiver.run();
    // run() only completes on an unrecoverable error; a clean shutdown goes
    // through the signal handler below instead.
    exit(1);
  } on ArchiverAuthException catch (e) {
    stderr.writeln('$e');
    exit(1);
  } finally {
    await archiver.stop();
    await signalR.disconnect();
    signalR.close();
    await db.close();
  }
}
