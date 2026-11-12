import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:test/test.dart';

void main() {
  _groupFanOutTests();
  _callSignalTests();
  _silentTests();
  _multiDeviceTests();

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
      'DeviceListChanged',
      'GroupChanged',
      'LinkOffer',
      'LinkConsent',
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

void _multiDeviceTests() {
  test('direct fan-out sends ids, declared recipients and payloads', () async {
    final (client, transport) = await _connected();
    await client.sendDirectFanout(
      'peer',
      {'peer': 'YQ==', 'peer-web': 'Yg=='},
      messageId: 'm1',
    );
    expect(transport.invocations, [
      [
        'SendReliableDirectFanout',
        'peer',
        'm1',
        ['peer', 'peer-web'],
        {'peer': 'YQ==', 'peer-web': 'Yg=='},
      ],
    ]);
  });

  test('an oversized fan-out is split per device but declares the full set', () async {
    final (client, transport) = await _connected();
    final big = 'x' * (500 * 1024);
    await client.sendGroupFanout('g', {'a': big, 'b': big}, messageId: 'm2');
    expect(transport.invocations, hasLength(2));
    for (final call in transport.invocations) {
      expect(call[0], 'SendReliableGroupFanout');
      expect(call[3], ['a', 'b']);
      expect((call[4] as Map).length, 1);
    }
  });

  test('link offer and consent use the hub contract', () async {
    final (client, transport) = await _connected();
    await client.sendLinkOffer('t');
    await client.sendLinkConsent('p', 'sig');
    expect(transport.invocations, [
      ['LinkOffer', 't'],
      ['LinkConsent', 'p', 'sig'],
    ]);
  });

  test('pending call methods use the call ringing hub contract', () async {
    final (client, transport) = await _connected();
    await client.requestPendingCalls();
    await client.declinePendingCall('c-1');
    expect(transport.invocations, [
      ['RequestPendingCalls'],
      ['DeclinePendingCall', 'c-1'],
    ]);
  });

  test('staleRequired extracts the device ids the server demands', () {
    expect(
      SignalRClient.staleRequired(
        Exception('HubException: device_list_stale:aa-1,bb-2'),
      ),
      {'aa-1', 'bb-2'},
    );
    expect(
      SignalRClient.staleRequired(Exception('device_list_stale:AA-1,Bb-2')),
      {'aa-1', 'bb-2'},
    );
    expect(SignalRClient.staleRequired(Exception('device_list_stale:')), <String>{});
    expect(SignalRClient.staleRequired(Exception('auditor_unavailable')), isNull);
  });

  test('device list and link events are forwarded', () async {
    final (client, transport) = await _connected();
    final changed = client.onDeviceListChanged.first;
    final offer = client.onLinkOffer.first;
    final consent = client.onLinkConsent.first;
    transport.handlers['DeviceListChanged']!([
      {'primaryDeviceId': 'p', 'version': 2},
    ]);
    transport.handlers['LinkOffer']!([
      {'primaryDeviceId': 'p'},
    ]);
    transport.handlers['LinkConsent']!([
      {'deviceId': 'd', 'consentSig': 's'},
    ]);
    expect((await changed)['version'], 2);
    expect((await offer)['primaryDeviceId'], 'p');
    expect((await consent)['consentSig'], 's');
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

// Spec 2026-11-11-bot-ack-reactions N1/N4: a silent reliable send goes to the
// `<method>Silent` twin with the same arguments; an old server without it
// gets the plain method instead, once per connection.
void _silentTests() {
  test('silent sends use the Silent twins with unchanged arguments', () async {
    final (client, transport) = await _connected();

    await client.sendMessage('bob', 'c', messageId: 'm1', silent: true);
    await client.sendGroupMessage('g', {'a': 'c'}, messageId: 'm2', silent: true);
    await client.sendDirectFanout('bob', {'b1': 'c'}, messageId: 'm3', silent: true);
    await client.sendGroupFanout('g', {'a1': 'c'}, messageId: 'm4', silent: true);
    // Default: the plain methods, byte for byte as before.
    await client.sendDirectFanout('bob', {'b1': 'c'}, messageId: 'm5');

    expect(transport.invocations, [
      ['SendReliableMessageSilent', 'bob', 'm1', 'c'],
      ['SendReliableGroupMessageSilent', 'g', 'm2', {'a': 'c'}],
      ['SendReliableDirectFanoutSilent', 'bob', 'm3', ['b1'], {'b1': 'c'}],
      ['SendReliableGroupFanoutSilent', 'g', 'm4', ['a1'], {'a1': 'c'}],
      ['SendReliableDirectFanout', 'bob', 'm5', ['b1'], {'b1': 'c'}],
    ]);
  });

  test('an old server without Silent methods gets the plain method', () async {
    final (client, transport) = await _connected();
    transport.unknown.addAll({
      'SendReliableDirectFanoutSilent',
      'SendReliableGroupFanoutSilent',
    });

    await client.sendDirectFanout('bob', {'b1': 'c'}, messageId: 'm1', silent: true);
    // Remembered for the connection: no second failing round trip.
    await client.sendGroupFanout('g', {'a1': 'c'}, messageId: 'm2', silent: true);

    expect(transport.invocations, [
      ['SendReliableDirectFanoutSilent', 'bob', 'm1', ['b1'], {'b1': 'c'}],
      ['SendReliableDirectFanout', 'bob', 'm1', ['b1'], {'b1': 'c'}],
      ['SendReliableGroupFanout', 'g', 'm2', ['a1'], {'a1': 'c'}],
    ]);
  });

  test('a hub error inside a Silent method is not a fallback', () async {
    late _FailingTransport transport;
    final client = SignalRClient(
      baseUrl: 'http://localhost',
      deviceId: 'device',
      transportFactory: (_, _) => transport = _FailingTransport(),
    );
    addTearDown(client.dispose);
    await client.connect();

    await expectLater(
      client.sendDirectFanout('bob', {'b1': 'c'}, messageId: 'm1', silent: true),
      throwsA(predicate((Object e) => SignalRClient.staleRequired(e) != null)),
    );
    expect(transport.invocations.map((i) => i.first), [
      'SendReliableDirectFanoutSilent',
    ]);
    expect(
      SignalRClient.isUnknownHubMethod(
        Exception("Failed to invoke 'X' due to an error on the server."),
        'X',
      ),
      isTrue,
    );
    expect(
      SignalRClient.isUnknownHubMethod(
        Exception("An unexpected error occurred invoking 'X' on the server."),
        'X',
      ),
      isFalse,
    );
  });
}

class _FailingTransport extends _FakeTransport {
  @override
  Future<void> invoke(String method, [List<Object> args = const []]) async {
    invocations.add([method, ...args]);
    throw Exception(
      "An unexpected error occurred invoking '$method' on the server. "
      'HubException: device_list_stale:b1,b2',
    );
  }
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

  /// Hub methods this fake server does not have (an older server).
  final unknown = <String>{};

  @override
  Future<void> invoke(String method, [List<Object> args = const []]) async {
    invocations.add([method, ...args]);
    if (unknown.contains(method)) {
      // What signalr_netcore surfaces for ASP.NET Core's binding failure.
      throw Exception(
        "Failed to invoke '$method' due to an error on the server.",
      );
    }
  }
}
