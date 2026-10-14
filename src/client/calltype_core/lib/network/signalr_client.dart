import 'dart:async';


import '../auth/auth_service.dart';
import 'hub_transport.dart';

/// Manages the SignalR connection to the CallType backend hub.
///
/// Provides typed methods for every hub operation (send message, typing,
/// call signaling) and exposes incoming events as broadcast streams so
/// multiple listeners (e.g. chat controller + notification service) can
/// subscribe independently.
///
/// Pure Dart on purpose (headless bots reuse it), so it cannot extend
/// Flutter's ChangeNotifier. Connection-state changes are reported through
/// the overridable [notifyListeners] hook instead; the app's subclass mixes
/// in ChangeNotifier there so widgets still rebuild (e.g. "offline" banner).
/// The wire library is injected as a [HubTransportFactory] for the same
/// reason — see hub_transport.dart.
///
/// Connection lifecycle:
///   1. Construct with baseUrl + deviceId
///   2. Call [connect] — builds the hub, registers handlers, starts
///   3. Use [sendMessage] / [sendGroupMessage] / etc.
///   4. Call [disconnect] or let [dispose] handle cleanup
///
/// The hub URL includes the deviceId as a query parameter because the
/// server uses it to track online devices and route messages. See
/// MessengerHub.cs on the server side.
class SignalRClient {
  SignalRClient({
    required String baseUrl,
    required String deviceId,
    required HubTransportFactory transportFactory,
    AuthService? authService,
  }) : _baseUrl = baseUrl,
       _deviceId = deviceId,
       _transportFactory = transportFactory,
       _authService = authService;

  /// Reconnect delays in ms: 2s, 5s, 10s, 20s, then give up.
  /// This matches the server's expected reconnection pattern —
  /// aggressive early retries for transient issues, backing off
  /// for sustained outages. Transports must honour it.
  static const retryDelaysMs = [2000, 5000, 10000, 20000];

  final HubTransportFactory _transportFactory;

  final String _baseUrl;
  String _deviceId;
  bool _disposed = false;
  Future<void>? _connecting;
  Timer? _pendingTimer;

  void setDeviceId(String value) {
    if (connected) throw StateError('Disconnect before changing identity.');
    _deviceId = value;
  }

  /// Hook called whenever [connected] may have changed. No-op here; the
  /// Flutter app overrides it (ChangeNotifier), a bot may ignore it.
  void notifyListeners() {}

  // Late hub callbacks can fire after dispose; listeners must not hear them.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  final AuthService? _authService;

  /// This device's UUID — exposed so feature controllers (e.g. chat) can
  /// determine message direction without a second SecureStorage read.
  String get deviceId => _deviceId;

  HubTransport? _hubConnection;

  // -- Broadcast streams for incoming events --------------------------------
  // Using broadcast controllers so multiple widgets/controllers can listen
  // independently. Each stream carries a decoded Map from the hub payload.

  final _onMessage = StreamController<Map<String, dynamic>>.broadcast();
  final _onTyping = StreamController<Map<String, dynamic>>.broadcast();
  final _onCallSignal = StreamController<Map<String, dynamic>>.broadcast();
  final _onChannelPost = StreamController<Map<String, dynamic>>.broadcast();
  final _onChannelDeleted = StreamController<Map<String, dynamic>>.broadcast();
  final _onEmergencyDrill = StreamController<Map<String, dynamic>>.broadcast();
  final _onDeviceListChanged =
      StreamController<Map<String, dynamic>>.broadcast();
  final _onLinkOffer = StreamController<Map<String, dynamic>>.broadcast();
  final _onLinkConsent = StreamController<Map<String, dynamic>>.broadcast();

  /// Multi-device: an identity this device belongs to changed its device
  /// list. Payload: `primaryDeviceId`, `version`. A hint to refetch and
  /// VERIFY; the event itself proves nothing.
  Stream<Map<String, dynamic>> get onDeviceListChanged =>
      _onDeviceListChanged.stream;

  /// Multi-device linking: a primary offers to link this device
  /// (`primaryDeviceId`). Only meaningful while the link screen is open.
  Stream<Map<String, dynamic>> get onLinkOffer => _onLinkOffer.stream;

  /// Multi-device linking: the new device's signed consent (`deviceId`,
  /// `consentSig`), delivered to the primary.
  Stream<Map<String, dynamic>> get onLinkConsent => _onLinkConsent.stream;

  /// Fires when a new encrypted message arrives from the server.
  /// Payload: {senderId, encryptedBody, createdAt, groupId?}
  Stream<Map<String, dynamic>> get onMessage => _onMessage.stream;

  /// Fires when a remote peer is typing in a conversation.
  /// Payload: {senderId, conversationId}
  Stream<Map<String, dynamic>> get onTyping => _onTyping.stream;

  /// Fires for WebRTC call signaling events (offer/answer/ICE/hangup).
  /// Payload: {senderId, signalType, payload}
  Stream<Map<String, dynamic>> get onCallSignal => _onCallSignal.stream;

  /// Fires for a new (or deleted — `deleted: true`) public channel post.
  /// Plaintext by design: channels are NOT end-to-end encrypted. The payload
  /// is parsed by `ChannelPostDto.fromJson` (channel_dtos.dart).
  Stream<Map<String, dynamic>> get onChannelPost => _onChannelPost.stream;

  /// Fires when a followed channel was deleted. Payload: {channelId}
  Stream<Map<String, dynamic>> get onChannelDeleted => _onChannelDeleted.stream;

  /// Fires when an org-admin starts an emergency drill (E07) — pushed only to
  /// currently-online members of the organization's emergency group, since
  /// there is no server-originated encrypted group-message path.
  /// Payload: {organizationId, drillId, startedAt}
  Stream<Map<String, dynamic>> get onEmergencyDrill => _onEmergencyDrill.stream;

  /// Whether the hub connection is currently active.
  bool get connected => _hubConnection?.isConnected ?? false;

  /// Establishes the SignalR connection to the backend hub.
  ///
  /// Builds the connection with automatic reconnect (exponential backoff),
  /// registers all server-to-client method handlers, then starts the
  /// connection. Queued messages are delivered by the server automatically
  /// on connect via the ReceiveMessage callback.
  Future<void> connect() async {
    if (_disposed) throw StateError('Connection disposed.');
    if (connected) return;
    if (_deviceId.isEmpty) throw StateError('Register this device first.');
    if (_connecting != null) return _connecting;
    _connecting = _connect();
    try {
      await _connecting;
    } finally {
      _connecting = null;
    }
  }

  Future<void> _connect() async {
    await _hubConnection?.stop();
    if (_disposed) return;
    // The hub is protected by [Authorize] on the server. WebSockets cannot
    // carry custom HTTP headers, so SignalR passes the JWT as the
    // `access_token` query parameter — the server moves it into the auth
    // pipeline in JwtBearerEvents.OnMessageReceived (see Program.cs).
    // The factory is consulted on every (re)connect, so an expired token
    // is transparently replaced after long offline periods.
    final authService = _authService;
    // Build the hub connection. The deviceId query parameter is kept for
    // server log correlation — the device identity itself is derived from
    // JWT claims on the server (MessengerHub.GetDeviceId).
    _hubConnection = _transportFactory(
      '$_baseUrl/hub?deviceId=$_deviceId',
      authService == null
          ? null
          : () async => await authService.getToken() ?? '',
    );

    // Register handlers for server-to-client methods.
    // Method names must match exactly what the server calls via SendAsync.
    _hubConnection!.on('ReceiveMessage', _handleReceiveMessage);
    _hubConnection!.on('TypingIndicator', _handleTypingIndicator);
    _hubConnection!.on('CallSignal', _handleCallSignal);
    _hubConnection!.on(
      'ReceiveChannelPost',
      (arguments) => _forward(arguments, _onChannelPost),
    );
    _hubConnection!.on(
      'ChannelDeleted',
      (arguments) => _forward(arguments, _onChannelDeleted),
    );
    _hubConnection!.on(
      'EmergencyDrill',
      (arguments) => _forward(arguments, _onEmergencyDrill),
    );
    _hubConnection!.on(
      'DeviceListChanged',
      (arguments) => _forward(arguments, _onDeviceListChanged),
    );
    _hubConnection!.on(
      'LinkOffer',
      (arguments) => _forward(arguments, _onLinkOffer),
    );
    _hubConnection!.on(
      'LinkConsent',
      (arguments) => _forward(arguments, _onLinkConsent),
    );

    // Notify UI when connection state changes (e.g. for offline banner).
    _hubConnection!.onClose(_notify);
    _hubConnection!.onReconnecting(_notify);
    _hubConnection!.onReconnected(() {
      unawaited(requestPendingMessages().catchError((Object _) {}));
      _notify();
    });

    await _hubConnection!.start();
    if (_disposed) {
      await _hubConnection!.stop();
      return;
    }
    _pendingTimer?.cancel();
    _pendingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (connected) {
        unawaited(requestPendingMessages().catchError((Object _) {}));
      }
    });
    _notify();
  }

  /// Closes the SignalR connection gracefully.
  Future<void> disconnect() async {
    _pendingTimer?.cancel();
    await _hubConnection?.stop();
    _notify();
  }

  // -- Client-to-server method invocations ----------------------------------

  /// Sends an encrypted message to a specific device.
  ///
  /// [recipientDeviceId] is the target device's UUID.
  /// [encryptedBodyBase64] is the base64-encoded ciphertext.
  ///
  /// The server routes this to the recipient if online, or queues it
  /// for later delivery if offline.
  Future<void> sendMessage(
    String recipientDeviceId,
    String encryptedBodyBase64, {
    String? messageId,
  }) async {
    await _requireConnection().invoke(
      messageId == null ? 'SendMessage' : 'SendReliableMessage',
      <Object>[recipientDeviceId, ?messageId, encryptedBodyBase64],
    );
  }

  /// Sends an encrypted group message to multiple devices.
  ///
  /// [groupId] is the group's UUID.
  /// [encryptedPayloads] maps deviceId -> base64 ciphertext for each
  /// group member (each gets a uniquely encrypted copy). Pass the WHOLE
  /// fan-out: in a business group the hub rejects any call that lacks the
  /// auditor's envelope (`audit_recipient_missing`, KB2), and one call is also
  /// one server transaction — every recipient is queued, or none.
  Future<void> sendGroupMessage(
    String groupId,
    Map<String, String> encryptedPayloads, {
    String? messageId,
  }) async {
    final connection = _requireConnection();
    final size = encryptedPayloads.values.fold(0, (n, v) => n + v.length);
    // ponytail: the hub accepts frames up to 1 MiB (Program.cs). A 256 KB
    // attachment for 3+ members does not fit, so that case falls back to one
    // call per recipient — fine in anonymous groups, but a business group
    // then fails with audit_recipient_missing. Upgrade path: attachments as
    // encrypted blobs instead of inline bodies.
    final calls = size <= _maxFanOutChars
        ? [encryptedPayloads]
        : [for (final e in encryptedPayloads.entries) {e.key: e.value}];
    for (final payloads in calls) {
      await connection.invoke(
        messageId == null ? 'SendGroupMessage' : 'SendReliableGroupMessage',
        <Object>[groupId, ?messageId, payloads],
      );
    }
  }

  /// Multi-device direct send: one envelope per device of the peer identity
  /// and of our own identity. [recipientIdentityId] is the peer's PRIMARY id.
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) => _fanout(
    'SendReliableDirectFanout',
    recipientIdentityId,
    messageId,
    encryptedPayloads,
  );

  /// Multi-device group send (non-business groups only; the hub rejects it
  /// for business groups, which stay on [sendGroupMessage]).
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) => _fanout(
    'SendReliableGroupFanout',
    groupId,
    messageId,
    encryptedPayloads,
  );

  Future<void> _fanout(
    String method,
    String target,
    String messageId,
    Map<String, String> encryptedPayloads,
  ) async {
    final connection = _requireConnection();
    // Every call declares the FULL device set: the hub checks completeness
    // on it, so a send that has to be split (attachment copies do not fit
    // one 1 MiB frame) still cannot silently skip a device.
    final all = encryptedPayloads.keys.toList();
    final size = encryptedPayloads.values.fold(0, (n, v) => n + v.length);
    final calls = size <= _maxFanOutChars
        ? [encryptedPayloads]
        : [for (final e in encryptedPayloads.entries) {e.key: e.value}];
    for (final payloads in calls) {
      await connection.invoke(method, <Object>[target, messageId, all, payloads]);
    }
  }

  /// The device ids the hub demanded in a `device_list_stale:<ids>` error,
  /// or null when [error] is something else.
  static Set<String>? staleRequired(Object error) {
    final match = RegExp(
      r'device_list_stale:([0-9a-fA-F,\-]*)',
    ).firstMatch(error.toString());
    if (match == null) return null;
    // Lowercased: the directory and the envelope keys are lowercase, and
    // reconcile compares them as plain strings.
    return match
        .group(1)!
        .split(',')
        .where((id) => id.isNotEmpty)
        .map((id) => id.toLowerCase())
        .toSet();
  }

  /// Linking, primary side: ask the scanned device to consent.
  Future<void> sendLinkOffer(String targetDeviceId) =>
      _requireConnection().invoke('LinkOffer', <Object>[targetDeviceId]);

  /// Linking, new-device side: answer with the signed consent.
  Future<void> sendLinkConsent(String primaryDeviceId, String consentSig) =>
      _requireConnection().invoke('LinkConsent', <Object>[
        primaryDeviceId,
        consentSig,
      ]);

  /// Headroom under the hub's 1 MiB frame limit for JSON framing and ids.
  static const _maxFanOutChars = 900 * 1024;

  Future<void> acknowledgeMessage(String senderId, String messageId) async {
    await _requireConnection().invoke(
      'AcknowledgeMessage',
      <Object>[senderId, messageId],
    );
  }

  Future<void> requestPendingMessages() async {
    await _requireConnection().invoke('RequestPendingMessages');
  }

  /// Subscribes this connection to the SignalR groups of every channel the
  /// device follows or administers. Group membership belongs to the
  /// connection, so it must be re-invoked after each (re)connect and after
  /// following a new channel.
  Future<void> joinChannels() => _requireConnection().invoke('JoinChannels');

  /// Stops live delivery for one channel after unfollowing it.
  Future<void> leaveChannel(String channelId) =>
      _requireConnection().invoke('LeaveChannel', <Object>[channelId]);

  HubTransport _requireConnection() {
    if (!connected) throw StateError('Offline. Reconnect and retry.');
    return _hubConnection!;
  }

  /// Sends a typing indicator to a conversation's participants.
  ///
  /// Fire-and-forget — typing indicators are ephemeral and not persisted.
  /// The server broadcasts to all other connected clients.
  Future<void> sendTypingIndicator(String conversationId) async {
    await _requireConnection().invoke(
      'TypingIndicator',
      <Object>[conversationId],
    );
  }

  /// Sends a WebRTC signaling message for voice/video calls.
  ///
  /// [targetDeviceId] is the call partner's device UUID.
  /// [signalType] is one of: 'offer', 'answer', 'ice-candidate', 'hangup'.
  /// [payload] is the SDP or ICE candidate JSON string.
  /// [businessGroupId], when set, marks this as a call inside a business
  /// conversation (H1): the hub then requires both devices to be members of
  /// that group and, on the offer, the organization's auditor to be alive.
  /// A business call goes out as a SEPARATE hub method, `BusinessCallSignal`
  /// — a C# optional parameter on `CallSignal` is not honored by SignalR's
  /// argument binder, so every pre-existing 3-argument caller (this method,
  /// unchanged, for an anonymous call) must keep sending exactly 3 arguments.
  Future<void> sendCallSignal(
    String targetDeviceId,
    String signalType,
    String payload, {
    String? businessGroupId,
  }) async {
    if (businessGroupId == null) {
      await _requireConnection().invoke(
        'CallSignal',
        <Object>[targetDeviceId, signalType, payload],
      );
    } else {
      await _requireConnection().invoke(
        'BusinessCallSignal',
        <Object>[targetDeviceId, signalType, payload, businessGroupId],
      );
    }
  }

  // -- Server-to-client handlers --------------------------------------------

  /// Handles incoming messages from the server.
  ///
  /// The server sends a list of arguments. For ReceiveMessage, the first
  /// (and only) argument is an object with senderId, encryptedBody, createdAt,
  /// and optionally groupId.
  void _handleReceiveMessage(List<Object?>? arguments) {
    if (_disposed) return;
    if (arguments == null || arguments.isEmpty) return;

    final data = _parseArgument(arguments[0]);
    if (data != null) {
      _onMessage.add(data);
    }
  }

  void _handleTypingIndicator(List<Object?>? arguments) {
    if (_disposed) return;
    if (arguments == null || arguments.isEmpty) return;

    final data = _parseArgument(arguments[0]);
    if (data != null) {
      _onTyping.add(data);
    }
  }

  void _handleCallSignal(List<Object?>? arguments) {
    if (_disposed) return;
    if (arguments == null || arguments.isEmpty) return;

    final data = _parseArgument(arguments[0]);
    if (data != null) {
      _onCallSignal.add(data);
    }
  }

  void _forward(
    List<Object?>? arguments,
    StreamController<Map<String, dynamic>> target,
  ) {
    if (_disposed || arguments == null || arguments.isEmpty) return;
    final data = _parseArgument(arguments[0]);
    if (data != null) target.add(data);
  }

  /// Safely casts a hub callback argument to a typed map.
  ///
  /// SignalR payloads arrive as dynamic objects — this normalizes them
  /// into `Map<String, dynamic>` for downstream consumers.
  Map<String, dynamic>? _parseArgument(Object? arg) {
    if (arg is Map) {
      return arg.cast<String, dynamic>();
    }
    return null;
  }

  /// Tears down the connection and streams. Named `close` (with [dispose]
  /// delegating to it) because the app's subclass mixes in ChangeNotifier,
  /// whose own `dispose` shadows this class's — it calls [close] explicitly.
  void close() {
    if (_disposed) return;
    _disposed = true;
    _pendingTimer?.cancel();
    _hubConnection?.stop();
    _onMessage.close();
    _onTyping.close();
    _onCallSignal.close();
    _onChannelPost.close();
    _onChannelDeleted.close();
    _onEmergencyDrill.close();
    _onDeviceListChanged.close();
    _onLinkOffer.close();
    _onLinkConsent.close();
  }

  void dispose() => close();
}
