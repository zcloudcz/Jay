import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:test/test.dart';

void main() {
  _groupFanOutTests();
  _callSignalTests();
  _x0MethodTests();

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
      'EmergencyDrill',
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

// KB2 (Business mode): the hub rejects any group call that lacks the auditor's
// envelope, so a fan-out split into one call per recipient can never succeed
// in a business group. Everything must travel in ONE call.
void _groupFanOutTests() {
  test('group fan-out goes out as ONE hub call carrying every recipient', () async {
    final (client, transport) = await _connected();

    await client.sendGroupMessage('g', {'bob': 'b', 'carol': 'c', 'auditor': 'a'}, messageId: 'm1');

    expect(transport.invocations, [
      ['SendReliableGroupMessage', 'g', 'm1', {'bob': 'b', 'carol': 'c', 'auditor': 'a'}],
    ]);
  });

  test('a fan-out over the hub frame limit falls back to one call per recipient', () async {
    final (client, transport) = await _connected();
    final big = 'x' * (500 * 1024);

    await client.sendGroupMessage('g', {'bob': big, 'carol': big}, messageId: 'm1');

    expect(transport.invocations.map((i) => (i[3] as Map).keys.single), ['bob', 'carol']);
  });
}

// H1: MessengerHub.CallSignal's businessGroupId is an OPTIONAL 4th parameter
// so already-deployed 3-argument callers keep working — the wire contract
// this guards is that an anonymous call sends exactly 3 args (unchanged) and
// a business call sends exactly 4, never a null placeholder in between.
void _callSignalTests() {
  test('anonymous call signal sends exactly 3 args, unchanged', () async {
    final (client, transport) = await _connected();

    await client.sendCallSignal('bob', 'offer', 'sdp');

    expect(transport.invocations, [
      ['CallSignal', 'bob', 'offer', 'sdp'],
    ]);
  });

  test('business call signal goes out as BusinessCallSignal with 4 args', () async {
    final (client, transport) = await _connected();

    await client.sendCallSignal(
      'bob',
      'offer',
      'sdp',
      businessGroupId: 'g1',
    );

    expect(transport.invocations, [
      ['BusinessCallSignal', 'bob', 'offer', 'sdp', 'g1'],
    ]);
  });
}

// X0 additions (contracts §5): hub names and argument order must match
// MessengerHub (X0-S, C) exactly.
void _x0MethodTests() {
  test('quiet direct message: SendQuietMessage(recipient, id, body)', () async {
    final (client, transport) = await _connected();
    await client.sendQuietMessage('bob', 'cipher', messageId: 'm1');
    expect(transport.invocations, [
      ['SendQuietMessage', 'bob', 'm1', 'cipher'],
    ]);
  });

  test('quiet group message is ONE call even when large', () async {
    final (client, transport) = await _connected();
    final big = 'x' * (500 * 1024);
    await client.sendQuietGroupMessage('g', {
      'bob': big,
      'auditor': big,
    }, messageId: 'm1');
    expect(transport.invocations.single[0], 'SendQuietGroupMessage');
    expect(transport.invocations.single[1], 'g');
    expect(transport.invocations.single[2], 'm1');
    expect((transport.invocations.single[3] as Map).keys, ['bob', 'auditor']);
  });

  test('direct fan-out: one SendReliableMessage per device, same id', () async {
    final (client, transport) = await _connected();
    await client.sendDirectFanout({'bob-1': 'a', 'bob-2': 'b'}, messageId: 'm');
    expect(transport.invocations, [
      ['SendReliableMessage', 'bob-1', 'm', 'a'],
      ['SendReliableMessage', 'bob-2', 'm', 'b'],
    ]);
    expect(
      () => client.sendDirectFanout({}, messageId: 'm'),
      throwsArgumentError,
    );
  });

  test('claimPendingCall sends one argument and returns the object', () async {
    final (client, transport) = await _connected();
    transport.results['ClaimPendingCall'] = {
      'status': 'ringing',
      'callerId': 'alice',
      'video': true,
    };
    final result = await client.claimPendingCall('call-1');
    expect(transport.invocations, [
      ['ClaimPendingCall', 'call-1'],
    ]);
    expect(result, {'status': 'ringing', 'callerId': 'alice', 'video': true});

    transport.results['ClaimPendingCall'] = null;
    expect(client.claimPendingCall('call-2'), throwsFormatException);
  });
}

/// Connected client + its fake transport, for wire-contract tests.
Future<(SignalRClient, _FakeTransport)> _connected() async {
  late _FakeTransport transport;
  final client = SignalRClient(
    baseUrl: 'http://localhost',
    deviceId: 'device',
    transportFactory: (_, _) => transport = _FakeTransport(),
  );
  addTearDown(client.dispose);
  await client.connect();
  return (client, transport);
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

  /// Canned hub return values by method name.
  final results = <String, Object?>{};

  @override
  Future<Object?> invoke(String method, [List<Object> args = const []]) async {
    invocations.add([method, ...args]);
    return results[method];
  }
}
