import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:signalr_netcore/signalr_client.dart';

/// The app's SignalR connection: the protocol logic lives in the pure-Dart
/// [core.SignalRClient] (shared with headless bots); this subclass only adds
/// the two Flutter-bound pieces the core cannot contain:
///   * [ChangeNotifier], so widgets rebuild on connection-state changes
///     (e.g. the "offline" banner via `context.watch<SignalRClient>()`);
///   * the `signalr_netcore` wire library, which depends on the Flutter SDK.
///
/// Same class name and constructor as before the core was extracted, so
/// feature code and tests did not have to change.
class SignalRClient extends core.SignalRClient with ChangeNotifier {
  SignalRClient({
    required super.baseUrl,
    required super.deviceId,
    super.authService,
  }) : super(transportFactory: _NetcoreHubTransport.new);

  @override
  void dispose() {
    // ChangeNotifier.dispose (the mixin) shadows the core's dispose, so the
    // connection teardown has to be requested explicitly.
    close();
    super.dispose();
  }
}

/// Adapts a `signalr_netcore` [HubConnection] to the core's [HubTransport].
class _NetcoreHubTransport implements HubTransport {
  _NetcoreHubTransport(
    String url,
    Future<String> Function()? accessTokenFactory,
  ) : _hub = HubConnectionBuilder()
          .withUrl(
            url,
            options: accessTokenFactory == null
                ? HttpConnectionOptions()
                : HttpConnectionOptions(accessTokenFactory: accessTokenFactory),
          )
          .withAutomaticReconnect(retryDelays: core.SignalRClient.retryDelaysMs)
          .build();

  final HubConnection _hub;

  @override
  bool get isConnected => _hub.state == HubConnectionState.Connected;

  @override
  void on(String method, void Function(List<Object?>? arguments) handler) =>
      _hub.on(method, handler);

  @override
  void onClose(void Function() callback) =>
      _hub.onclose(({Exception? error}) => callback());

  @override
  void onReconnecting(void Function() callback) =>
      _hub.onreconnecting(({Exception? error}) => callback());

  @override
  void onReconnected(void Function() callback) =>
      _hub.onreconnected(({String? connectionId}) => callback());

  @override
  Future<void> start() async => await _hub.start();

  @override
  Future<void> stop() => _hub.stop();

  @override
  Future<void> invoke(String method, [List<Object> args = const []]) =>
      // Copy: signalr_netcore may mutate the list (stream params), and the
      // core's default is an unmodifiable const list.
      _hub.invoke(method, args: List.of(args));
}
