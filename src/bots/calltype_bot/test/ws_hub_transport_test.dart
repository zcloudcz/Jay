import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _rs = '';

/// A tiny SignalR-speaking server: answers the handshake, completes every
/// invocation (with an error for the target "Fail"), records what it saw.
class _FakeSignalRServer {
  _FakeSignalRServer._(this._server);
  final HttpServer _server;
  final sockets = <WebSocket>[];
  final tokens = <String?>[];
  final frames = <Map<String, dynamic>>[];

  /// Simulates the dead session: these sockets stay open (and dart:io still
  /// answers WebSocket pings) but the server sends nothing on them any more.
  /// Connections opened later behave normally.
  final silenced = <WebSocket>{};
  void silenceAll() => silenced.addAll(sockets);

  String get url => 'http://127.0.0.1:${_server.port}/hub?deviceId=d1';

  static Future<_FakeSignalRServer> start() async {
    final fake = _FakeSignalRServer._(await HttpServer.bind('127.0.0.1', 0));
    fake._server.listen((request) async {
      fake.tokens.add(request.uri.queryParameters['access_token']);
      expect(request.uri.queryParameters['deviceId'], 'd1');
      final socket = await WebSocketTransformer.upgrade(request);
      fake.sockets.add(socket);
      socket.listen((data) {
        for (final raw in (data as String).split(_rs)) {
          if (raw.isEmpty) continue;
          final frame = jsonDecode(raw) as Map<String, dynamic>;
          if (fake.silenced.contains(socket)) {
            fake.frames.add(frame);
            continue;
          }
          if (frame['protocol'] == 'json') {
            socket.add('{}$_rs');
            continue;
          }
          fake.frames.add(frame);
          if (frame['type'] == 1) {
            socket.add(
              '${jsonEncode({
                'type': 3,
                'invocationId': frame['invocationId'],
                if (frame['target'] == 'Fail') 'error': 'nope',
              })}$_rs',
            );
          }
        }
      });
    });
    return fake;
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _FakeSignalRServer server;
  late WebSocketHubTransport transport;
  var tokenCalls = 0;

  setUp(() async {
    server = await _FakeSignalRServer.start();
    tokenCalls = 0;
    transport = WebSocketHubTransport(
      server.url,
      () async => 'jwt-${++tokenCalls}',
      retryDelaysMs: const [10],
    );
  });

  tearDown(() async {
    await transport.stop();
    await server.close();
  });

  test('handshake, token in query, invoke completes, hub errors surface', () async {
    await transport.start();
    expect(transport.isConnected, isTrue);
    expect(server.tokens.single, 'jwt-1');

    await transport.invoke('AcknowledgeMessage', ['s', 'm']);
    expect(server.frames.last['target'], 'AcknowledgeMessage');
    expect(server.frames.last['arguments'], ['s', 'm']);

    expect(transport.invoke('Fail'), throwsStateError);
  });

  test('server invocations reach the registered handler', () async {
    final received = <List<Object?>?>[];
    transport.on('ReceiveMessage', received.add);
    await transport.start();

    server.sockets.single.add(
      '${jsonEncode({
        'type': 1,
        'target': 'ReceiveMessage',
        'arguments': [
          {'senderId': 'x'},
        ],
      })}$_rs{"type":6}$_rs',
    );
    await until(() => received.isNotEmpty);
    expect((received.single!.single as Map)['senderId'], 'x');
  });

  test('reconnects after a drop with a FRESH token and reports it', () async {
    final events = <String>[];
    transport.onReconnecting(() => events.add('reconnecting'));
    transport.onReconnected(() => events.add('reconnected'));
    await transport.start();

    await server.sockets.single.close();
    await until(() => events.contains('reconnected'));

    expect(events, ['reconnecting', 'reconnected']);
    expect(server.tokens, ['jwt-1', 'jwt-2']);
    await transport.invoke('RequestPendingMessages');
  });

  test('a silent server is detected and the session reconnects', () async {
    final logs = <String>[];
    final events = <String>[];
    final watched = WebSocketHubTransport(
      server.url,
      () async => 'jwt-${++tokenCalls}',
      retryDelaysMs: const [10],
      serverTimeout: const Duration(milliseconds: 300),
      keepAliveInterval: const Duration(milliseconds: 50),
      log: logs.add,
    );
    addTearDown(watched.stop);
    watched.onReconnecting(() => events.add('reconnecting'));
    watched.onReconnected(() => events.add('reconnected'));
    final received = <List<Object?>?>[];
    watched.on('ReceiveMessage', received.add);
    await watched.start();

    // The old session goes deaf; an invocation on it waits for nothing.
    server.silenceAll();
    final stuck = watched.invoke('AcknowledgeMessage', ['s', 'm']);
    final stuckResult = expectLater(stuck, throwsA(anything));
    await until(() => events.contains('reconnected'));
    await stuckResult;

    expect(server.sockets, hasLength(2));
    expect(logs.first, contains('nothing from the server'));
    expect(logs.last, contains('reconnected'));
    await watched.invoke('RequestPendingMessages');

    server.sockets.last.add(
      '${jsonEncode({
        'type': 1,
        'target': 'ReceiveMessage',
        'arguments': [
          {'senderId': 'y'},
        ],
      })}$_rs',
    );
    await until(() => received.isNotEmpty);
  });

  test('a healthy server that only pings keeps the session', () async {
    final logs = <String>[];
    final watched = WebSocketHubTransport(
      server.url,
      () async => 'jwt',
      serverTimeout: const Duration(milliseconds: 300),
      keepAliveInterval: const Duration(milliseconds: 50),
      log: logs.add,
    );
    addTearDown(watched.stop);
    await watched.start();
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      server.sockets.single.add('{"type":6}$_rs');
    }
    expect(server.sockets, hasLength(1));
    expect(logs, isEmpty);
    expect(watched.isConnected, isTrue);
  });

  test('an invocation without a completion times out', () async {
    final watched = WebSocketHubTransport(
      server.url,
      () async => 'jwt',
      serverTimeout: const Duration(minutes: 1),
      invocationTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(watched.stop);
    await watched.start();
    server.silenceAll();
    await expectLater(
      watched.invoke('AcknowledgeMessage', ['s', 'm']),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('invoke while disconnected fails instead of hanging', () {
    expect(transport.invoke('X'), throwsStateError);
  });
}
