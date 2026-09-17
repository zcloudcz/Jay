import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:test/test.dart';

void main() {
  test('offline send fails instead of claiming successful delivery', () async {
    final client = SignalRClient(
      baseUrl: 'http://localhost',
      deviceId: 'device',
      // Never reached: sends are rejected before any connection is built.
      transportFactory: (_, _) => throw UnimplementedError(),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.sendMessage('recipient', 'ciphertext'),
      throwsStateError,
    );
    await expectLater(
      client.sendGroupMessage('group', {'recipient': 'ciphertext'}),
      throwsStateError,
    );
    await expectLater(
      client.sendCallSignal('recipient', 'offer', 'sdp'),
      throwsStateError,
    );
  });

  // Guards the HubTransport seam: hub method names and argument order are the
  // wire contract with MessengerHub.cs and must survive any transport swap.
  test('drives an injected transport with the exact hub contract', () async {
    late _FakeTransport transport;
    late String url;
    var notifications = 0;
    final client = _CountingClient(
      onNotify: () => notifications++,
      transportFactory: (u, tokenFactory) {
        url = u;
        return transport = _FakeTransport();
      },
    );
    addTearDown(client.dispose);

    await client.connect();
    expect(url, 'http://localhost/hub?deviceId=device');
    expect(client.connected, isTrue);
    expect(notifications, 1);
    expect(transport.handlers.keys, {
      'ReceiveMessage',
      'TypingIndicator',
      'CallSignal',
      'ReceiveChannelPost',
      'ChannelDeleted',
    });

    await client.sendMessage('bob', 'cipher', messageId: 'm1');
    await client.sendMessage('bob', 'cipher');
    expect(transport.invocations, [
      ['SendReliableMessage', 'bob', 'm1', 'cipher'],
      ['SendMessage', 'bob', 'cipher'],
    ]);

    final received = client.onMessage.first;
    transport.handlers['ReceiveMessage']!([
      {'senderId': 'bob', 'encryptedBody': 'x'},
    ]);
    expect((await received)['senderId'], 'bob');

    // Channel wire contract: hub method names + the two plaintext events.
    transport.invocations.clear();
    await client.joinChannels();
    await client.leaveChannel('ch1');
    expect(transport.invocations, [
      ['JoinChannels'],
      ['LeaveChannel', 'ch1'],
    ]);
    final post = client.onChannelPost.first;
    final deleted = client.onChannelDeleted.first;
    transport.handlers['ReceiveChannelPost']!([
      {'channelId': 'ch1', 'postId': 'p1'},
    ]);
    transport.handlers['ChannelDeleted']!([
      {'channelId': 'ch1'},
    ]);
    expect((await post)['postId'], 'p1');
    expect((await deleted)['channelId'], 'ch1');

    // A reconnect must re-request queued messages and tell listeners.
    transport.invocations.clear();
    transport.reconnected!();
    expect(transport.invocations, [
      ['RequestPendingMessages'],
    ]);
    expect(notifications, 2);
  });
}

class _CountingClient extends SignalRClient {
  _CountingClient({required this.onNotify, required super.transportFactory})
    : super(baseUrl: 'http://localhost', deviceId: 'device');

  final void Function() onNotify;

  @override
  void notifyListeners() => onNotify();
}

class _FakeTransport implements HubTransport {
  final handlers = <String, void Function(List<Object?>?)>{};
  final invocations = <List<Object>>[];
  void Function()? reconnected;

  @override
  bool isConnected = false;

  @override
  void on(String method, void Function(List<Object?>? arguments) handler) =>
      handlers[method] = handler;

  @override
  void onClose(void Function() callback) {}

  @override
  void onReconnecting(void Function() callback) {}

  @override
  void onReconnected(void Function() callback) => reconnected = callback;

  @override
  Future<void> start() async => isConnected = true;

  @override
  Future<void> stop() async => isConnected = false;

  @override
  Future<void> invoke(String method, [List<Object> args = const []]) async =>
      invocations.add([method, ...args]);
}
