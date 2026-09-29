/// The handful of SignalR hub-connection operations [SignalRClient] needs.
///
/// WHY this seam exists: the app's SignalR library (`signalr_netcore`)
/// declares a dependency on the Flutter SDK, so the pure-Dart core cannot
/// import it. Everything protocol-relevant (hub method names, argument
/// order, pending-message polling, event streams) stays in [SignalRClient];
/// only the wire library is plugged in. The app adapts `signalr_netcore`
/// (see the app's core/network/signalr_client.dart); a headless bot adapts
/// any pure-Dart SignalR client the same way.
abstract class HubTransport {
  /// True only while the connection is fully established (not while
  /// connecting or reconnecting) — sends are rejected otherwise.
  bool get isConnected;

  /// Registers a handler for a server-to-client hub method.
  void on(String method, void Function(List<Object?>? arguments) handler);

  void onClose(void Function() callback);
  void onReconnecting(void Function() callback);
  void onReconnected(void Function() callback);

  Future<void> start();
  Future<void> stop();

  /// Invokes a hub method and completes with its return value (null for a
  /// `Task` method). `Future<Object?>` since X0: `ClaimPendingCall` (C) is
  /// the first hub method that returns something. A transport declared with
  /// the older `Future<void> invoke` still satisfies this signature (void
  /// and Object? are both top types) and passes the value through at
  /// runtime as long as it returns the library's future unchanged.
  Future<Object?> invoke(String method, [List<Object> args = const []]);
}

/// Builds a [HubTransport] for [url]. Called on every (re)connect attempt.
///
/// [accessTokenFactory] must be consulted by the transport on each
/// (re)connect so an expired JWT is replaced after long offline periods;
/// null means an unauthenticated connection (tests only).
///
/// Implementations should reconnect automatically using
/// [SignalRClient.retryDelaysMs].
typedef HubTransportFactory =
    HubTransport Function(
      String url,
      Future<String> Function()? accessTokenFactory,
    );
