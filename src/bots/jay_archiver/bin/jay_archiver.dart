import 'dart:async';
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
/// `jay_archiver run [--api <url>] [--org <orgId>] [--state <dir>]`
///
/// `run`'s three flags fall back to `JAY_API_URL` / `JAY_ORG_ID` /
/// `JAY_STATE_DIR` (see [resolveOptions]) so a container only needs env vars,
/// no command override, in its `docker-compose.yml`.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: jay_archiver <provision|run> --api <url> --org <orgId> --state <dir> [--admin-token <jwt>]\n'
      '  ("run" also reads JAY_API_URL / JAY_ORG_ID / JAY_STATE_DIR from the environment.)',
    );
    exit(64);
  }
  final command = args.first;
  final flags = parseFlags(args.skip(1));

  final CliOptions opts;
  try {
    opts = resolveOptions(
      flags,
      Platform.environment,
      requireAdminToken: command == 'provision',
    );
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }

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

/// Registers a fresh bot device (isBot: true) and makes it the organization's
/// auditor. Prints only the device id — the store directory holds the keys.
Future<void> _provision(CliOptions opts) async {
  // CallTypeBot.start() already does exactly what an auditor device needs at
  // provisioning time: register with isBot: true and persist keys/secret in
  // EncryptedFileStore. It is never connected here (no onMessage call), so
  // this is a one-shot registration, not a running bot.
  final bot = await CallTypeBot.start(
    apiBaseUrl: opts.apiBaseUrl,
    storePath: opts.statePath,
    displayName: 'Jay Archiver',
    log: (_) {}, // registration confirmation would leak the handle/deviceId twice; caller reads stdout below
  );

  // PUT /orgs/{orgId}/auditor is owned by E01 — called here with the
  // caller-supplied admin JWT, never this device's own token (a fresh
  // auditor device has no organization membership of its own to authorize with).
  final admin = Dio(BaseOptions(baseUrl: opts.apiBaseUrl, headers: {'Authorization': 'Bearer ${opts.adminToken}'}));
  await admin.put('/orgs/${opts.orgId}/auditor', data: {'deviceId': bot.deviceId});

  await bot.close();
  stdout.writeln(bot.deviceId);
}

/// Connects as the already-provisioned auditor device and archives forever.
Future<void> _run(CliOptions opts) async {
  final key = EncryptedFileStore.parseKey(Platform.environment['BOT_STORE_KEY']);
  final store = await EncryptedFileStore.open(opts.statePath, key);
  final deviceId = await store.getDeviceId();
  if (deviceId == null) {
    stderr.writeln('No device in "${opts.statePath}" — run "provision" first.');
    exit(1);
  }

  final db = AppDatabase(NativeDatabase(File('${opts.statePath}.sqlite')));
  final keys = KeyManager(secureStorage: store);
  final auth = AuthService(secureStorage: store, baseUrl: opts.apiBaseUrl);
  final api = ApiClient(baseUrl: opts.apiBaseUrl, authService: auth);
  final sessions = SessionManager(database: db, keyManager: keys);
  final signalR = SignalRClient(
    baseUrl: opts.apiBaseUrl,
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
    organizationId: opts.orgId,
    log: stderr.writeln,
  );

  // Graceful shutdown: stop consuming, disconnect, close the DB, exit clean.
  // Runs from a signal handler rather than through archiver.run()'s own
  // completion (that future only ever completes on an unrecoverable error),
  // so it bypasses the try/finally below and closes everything itself.
  // ProcessSignal.sigterm has no meaning on Windows (dart:io throws if
  // watched there) — this only matters for local dev, containers are Linux.
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal _) async {
    if (shuttingDown) return;
    shuttingDown = true;
    stderr.writeln('Shutting down.');
    await archiver.stop();
    await signalR.disconnect();
    signalR.close();
    await db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);

  try {
    await signalR.connect();
  } catch (e) {
    // API unreachable at startup (container racing the API's own boot, or a
    // real outage): a one-line log and a non-zero exit lets the restart
    // policy retry, instead of a raw stack trace dump.
    stderr.writeln('Cannot reach the CallType API: $e');
    await db.close();
    exit(69); // EX_UNAVAILABLE
  }
  await signalR.requestPendingMessages();
  stdout.writeln('Archiving organization ${opts.orgId} as device $deviceId...');

  try {
    await archiver.run();
    // run() only completes on an unrecoverable error; a clean shutdown goes
    // through the signal handler above instead.
    exit(1);
  } on ArchiverAuthException catch (e) {
    stderr.writeln('$e');
    exit(1);
  } finally {
    if (!shuttingDown) {
      await archiver.stop();
      await signalR.disconnect();
      signalR.close();
      await db.close();
    }
  }
}
