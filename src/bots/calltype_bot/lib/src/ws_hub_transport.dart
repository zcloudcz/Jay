import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';

/// Minimal SignalR client (JSON hub protocol over WebSocket) on `dart:io`.
///
/// WHY hand-rolled: the app's `signalr_netcore` needs the Flutter SDK, and
/// the pure-Dart `signalr_core` is unmaintained and pins old `web` /
/// `web_socket_channel` versions. The bot needs only a sliver of SignalR:
/// invoke-with-completion, server-to-client invocations and keep-alive.
///
/// WHY no `/negotiate` round-trip: ASP.NET Core accepts a direct WebSocket
/// upgrade on the hub URL ("skip negotiation"), which is valid exactly when
/// WebSockets is the only transport — our case.
///
/// Protocol recap: every frame is JSON terminated by 0x1E. After the socket
/// opens the client sends `{"protocol":"json","version":1}` and the server
/// answers `{}` (or `{"error":…}`). Then: type 1 = invocation, 3 =
/// completion, 6 = ping, 7 = close.
class WebSocketHubTransport implements HubTransport {
  WebSocketHubTransport(
    this._url,
    this._accessTokenFactory, {
    List<int> retryDelaysMs = SignalRClient.retryDelaysMs,
  }) : _retryDelaysMs = retryDelaysMs;

  static const _separator = '';

  final String _url;
  final Future<String> Function()? _accessTokenFactory;
  final List<int> _retryDelaysMs;

  final _handlers = <String, void Function(List<Object?>?)>{};
  final _pending = <String, Completer<void>>{};
  void Function()? _onClose;
  void Function()? _onReconnecting;
  void Function()? _onReconnected;

  WebSocket? _socket;
  Timer? _keepAlive;
  bool _connected = false;
  bool _stopped = false;
  int _nextInvocationId = 0;

  @override
  bool get isConnected => _connected;

  @override
  void on(String method, void Function(List<Object?>? arguments) handler) =>
      _handlers[method] = handler;

  @override
  void onClose(void Function() callback) => _onClose = callback;

  @override
  void onReconnecting(void Function() callback) => _onReconnecting = callback;

  @override
  void onReconnected(void Function() callback) => _onReconnected = callback;

  @override
  Future<void> start() => _open();

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _teardown(StateError('Connection stopped.'));
    await _socket?.close();
    _onClose?.call();
  }

  @override
  Future<void> invoke(String method, [List<Object> args = const []]) {
    final socket = _socket;
    if (!_connected || socket == null) {
      return Future.error(StateError('Hub is not connected.'));
    }
    final id = '${_nextInvocationId++}';
    final completer = _pending[id] = Completer<void>();
    socket.add(
      '${jsonEncode({'type': 1, 'invocationId': id, 'target': method, 'arguments': args})}$_separator',
    );
    return completer.future;
  }

  Future<void> _open() async {
    // A fresh token per attempt: after a long outage the cached JWT may
    // have expired, and the hub rejects the upgrade without a valid one.
    final token = await _accessTokenFactory?.call();
    var uri = Uri.parse(_url);
    uri = uri.replace(
      scheme: uri.scheme == 'https' ? 'wss' : 'ws',
      queryParameters: {
        ...uri.queryParameters,
        // Browsers cannot set headers on a WebSocket, so the server reads the
        // JWT from this query parameter (see Program.cs OnMessageReceived).
        if (token != null && token.isNotEmpty) 'access_token': token,
      },
    );
    final socket = await WebSocket.connect(uri.toString());
    // WebSocket-level pings detect a silently dead TCP connection; dart:io
    // closes the socket when a pong is missed, which triggers the reconnect.
    socket.pingInterval = const Duration(seconds: 15);
    _socket = socket;

    final handshake = Completer<void>();
    socket.listen(
      (data) {
        if (data is! String) return;
        for (final frame in data.split(_separator)) {
          if (frame.isEmpty) continue;
          final message = jsonDecode(frame) as Map<String, dynamic>;
          if (!handshake.isCompleted) {
            final error = message['error'];
            error == null
                ? handshake.complete()
                : handshake.completeError(StateError('Handshake: $error'));
            continue;
          }
          _dispatch(message);
        }
      },
      onDone: () => _onSocketClosed(socket, handshake),
      onError: (Object _) => _onSocketClosed(socket, handshake),
      cancelOnError: true,
    );
    socket.add('{"protocol":"json","version":1}$_separator');
    try {
      await handshake.future.timeout(const Duration(seconds: 15));
      if (_stopped) throw StateError('Stopped while connecting.');
    } catch (_) {
      unawaited(socket.close());
      rethrow;
    }

    _connected = true;
    // SignalR-level ping: the server drops clients that stay silent for its
    // ClientTimeoutInterval (30 s by default), so speak at half that.
    _keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_connected) socket.add('{"type":6}$_separator');
    });
  }

  void _dispatch(Map<String, dynamic> message) {
    switch (message['type']) {
      case 1:
        _handlers[message['target']]?.call(
          (message['arguments'] as List?)?.cast<Object?>(),
        );
      case 3:
        final completer = _pending.remove(message['invocationId']);
        final error = message['error'];
        if (error == null) {
          completer?.complete();
        } else {
          completer?.completeError(StateError('Hub error: $error'));
        }
      case 7:
        // Server-initiated close; the socket's onDone does the rest.
        _socket?.close();
    }
  }

  void _onSocketClosed(WebSocket socket, Completer<void> handshake) {
    if (!handshake.isCompleted) {
      handshake.completeError(StateError('Closed during handshake.'));
      return; // start()/_reconnect() see the error and decide what is next.
    }
    if (socket != _socket || _stopped) return;
    _teardown(StateError('Connection lost.'));
    unawaited(_reconnect());
  }

  /// Fails in-flight invocations — their completions can never arrive on a
  /// new connection, and a caller awaiting forever would stall its queue.
  void _teardown(Object reason) {
    _connected = false;
    _keepAlive?.cancel();
    for (final completer in _pending.values) {
      completer.completeError(reason);
    }
    _pending.clear();
  }

  Future<void> _reconnect() async {
    _onReconnecting?.call();
    // WHY retry forever (the app gives up after the listed delays): the app
    // has a user who can tap "retry"; a bot has nobody. After the listed
    // delays it keeps trying at the last (longest) one.
    for (var attempt = 0; !_stopped; attempt++) {
      final delay = _retryDelaysMs[attempt < _retryDelaysMs.length
          ? attempt
          : _retryDelaysMs.length - 1];
      await Future<void>.delayed(Duration(milliseconds: delay));
      if (_stopped) return;
      try {
        await _open();
        _onReconnected?.call();
        return;
      } catch (_) {
        // Server still unreachable (or token endpoint down) — next attempt.
      }
    }
  }
}
