import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:signalr_netcore/signalr_client.dart';

/// Manages the SignalR connection to the ZMessanger backend hub.
///
/// Provides typed methods for every hub operation (send message, typing,
/// call signaling) and exposes incoming events as broadcast streams so
/// multiple listeners (e.g. chat controller + notification service) can
/// subscribe independently.
///
/// Extends [ChangeNotifier] so UI widgets can rebuild when the connection
/// state changes (e.g. showing an "offline" banner).
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
class SignalRClient extends ChangeNotifier {
  SignalRClient({
    required String baseUrl,
    required String deviceId,
  })  : _baseUrl = baseUrl,
        _deviceId = deviceId;

  final String _baseUrl;
  final String _deviceId;

  HubConnection? _hubConnection;

  // -- Broadcast streams for incoming events --------------------------------
  // Using broadcast controllers so multiple widgets/controllers can listen
  // independently. Each stream carries a decoded Map from the hub payload.

  final _onMessage = StreamController<Map<String, dynamic>>.broadcast();
  final _onTyping = StreamController<Map<String, dynamic>>.broadcast();
  final _onCallSignal = StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when a new encrypted message arrives from the server.
  /// Payload: {senderId, encryptedBody, createdAt, groupId?}
  Stream<Map<String, dynamic>> get onMessage => _onMessage.stream;

  /// Fires when a remote peer is typing in a conversation.
  /// Payload: {senderId, conversationId}
  Stream<Map<String, dynamic>> get onTyping => _onTyping.stream;

  /// Fires for WebRTC call signaling events (offer/answer/ICE/hangup).
  /// Payload: {senderId, signalType, payload}
  Stream<Map<String, dynamic>> get onCallSignal => _onCallSignal.stream;

  /// Whether the hub connection is currently active.
  bool get connected => _hubConnection?.state == HubConnectionState.Connected;

  /// Establishes the SignalR connection to the backend hub.
  ///
  /// Builds the connection with automatic reconnect (exponential backoff),
  /// registers all server-to-client method handlers, then starts the
  /// connection. Queued messages are delivered by the server automatically
  /// on connect via the ReceiveMessage callback.
  Future<void> connect() async {
    // Build the hub connection. The deviceId query parameter is how the
    // server maps this connection to our device — see MessengerHub.OnConnectedAsync.
    _hubConnection = HubConnectionBuilder()
        .withUrl('$_baseUrl/hub?deviceId=$_deviceId')
        .withAutomaticReconnect(
          // Retry delays in ms: 2s, 5s, 10s, 20s, then give up (null).
          // This matches the server's expected reconnection pattern —
          // aggressive early retries for transient issues, backing off
          // for sustained outages.
          retryDelays: [2000, 5000, 10000, 20000],
        )
        .build();

    // Register handlers for server-to-client methods.
    // Method names must match exactly what the server calls via SendAsync.
    _hubConnection!.on('ReceiveMessage', _handleReceiveMessage);
    _hubConnection!.on('TypingIndicator', _handleTypingIndicator);
    _hubConnection!.on('CallSignal', _handleCallSignal);

    // Notify UI when connection state changes (e.g. for offline banner).
    _hubConnection!.onclose(({Exception? error}) {
      notifyListeners();
    });
    _hubConnection!.onreconnecting(({Exception? error}) {
      notifyListeners();
    });
    _hubConnection!.onreconnected(({String? connectionId}) {
      notifyListeners();
    });

    await _hubConnection!.start();
    notifyListeners();
  }

  /// Closes the SignalR connection gracefully.
  Future<void> disconnect() async {
    await _hubConnection?.stop();
    notifyListeners();
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
    String encryptedBodyBase64,
  ) async {
    await _hubConnection?.invoke(
      'SendMessage',
      args: <Object>[recipientDeviceId, encryptedBodyBase64],
    );
  }

  /// Sends an encrypted group message to multiple devices.
  ///
  /// [groupId] is the group's UUID.
  /// [encryptedPayloads] maps deviceId -> base64 ciphertext for each
  /// group member (each gets a uniquely encrypted copy).
  Future<void> sendGroupMessage(
    String groupId,
    Map<String, String> encryptedPayloads,
  ) async {
    await _hubConnection?.invoke(
      'SendGroupMessage',
      args: <Object>[groupId, encryptedPayloads],
    );
  }

  /// Sends a typing indicator to a conversation's participants.
  ///
  /// Fire-and-forget — typing indicators are ephemeral and not persisted.
  /// The server broadcasts to all other connected clients.
  Future<void> sendTypingIndicator(String conversationId) async {
    await _hubConnection?.invoke(
      'TypingIndicator',
      args: <Object>[conversationId],
    );
  }

  /// Sends a WebRTC signaling message for voice/video calls.
  ///
  /// [targetDeviceId] is the call partner's device UUID.
  /// [signalType] is one of: 'offer', 'answer', 'ice-candidate', 'hangup'.
  /// [payload] is the SDP or ICE candidate JSON string.
  Future<void> sendCallSignal(
    String targetDeviceId,
    String signalType,
    String payload,
  ) async {
    await _hubConnection?.invoke(
      'CallSignal',
      args: <Object>[targetDeviceId, signalType, payload],
    );
  }

  // -- Server-to-client handlers --------------------------------------------

  /// Handles incoming messages from the server.
  ///
  /// The server sends a list of arguments. For ReceiveMessage, the first
  /// (and only) argument is an object with senderId, encryptedBody, createdAt,
  /// and optionally groupId.
  void _handleReceiveMessage(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;

    final data = _parseArgument(arguments[0]);
    if (data != null) {
      _onMessage.add(data);
    }
  }

  void _handleTypingIndicator(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;

    final data = _parseArgument(arguments[0]);
    if (data != null) {
      _onTyping.add(data);
    }
  }

  void _handleCallSignal(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;

    final data = _parseArgument(arguments[0]);
    if (data != null) {
      _onCallSignal.add(data);
    }
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

  @override
  void dispose() {
    _hubConnection?.stop();
    _onMessage.close();
    _onTyping.close();
    _onCallSignal.close();
    super.dispose();
  }
}
