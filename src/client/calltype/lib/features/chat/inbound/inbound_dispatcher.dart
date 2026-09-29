import 'package:calltype_core/messaging/control_messages.dart';

import 'content_handler.dart';
import 'inbound_handler.dart';

/// Observer of every valid payload (D: reads the optional `dlv` field of
/// direct messages). Runs inside the inbox transaction like a handler.
typedef InboundPayloadObserver = Future<void> Function(InboundContext ctx);

/// Registry of incoming-message handlers by wire `type` (contracts K3).
///
/// Streams M, M2, G and D add behaviour by REGISTERING a handler — none of
/// them edits the inbox. Types without a handler follow contracts K1:
/// - control (`ctl: true` or a known control type) → [Ignored]: logged in
///   `InboundLog` and acknowledged, so an older app never blocks the queue;
/// - content → stored verbatim ([ContentMessageHandler.unknown]) and shown
///   as "needs a newer version of Jay", so nothing sent in the meantime is
///   lost once the app is updated.
class InboundDispatcher {
  InboundDispatcher() {
    register(MessageTypes.text, ContentMessageHandler.text);
    register(MessageTypes.file, ContentMessageHandler.file);
    register(MessageTypes.callEvent, ContentMessageHandler.callEvent);
  }

  final _handlers = <String, InboundTypeHandler>{};
  final _observers = <InboundPayloadObserver>[];

  /// Registers (or replaces) the handler for [type]. Call before the inbox
  /// starts; replacing lets a later stream take over a type (e.g. M2 for
  /// `media`, which is stored by the unknown-content path until then).
  void register(String type, InboundTypeHandler handler) {
    if (type == MessageTypes.system) {
      throw ArgumentError('system is local-only and never received');
    }
    _handlers[type] = handler;
  }

  void addPayloadObserver(InboundPayloadObserver observer) =>
      _observers.add(observer);

  /// Dispatches one message. Re-entrant: a handler (D's `sync`) may call it
  /// again with `ctx.copyWith(...)` for the content it unpacks.
  Future<InboundResult> dispatch(InboundContext ctx) async {
    for (final observer in _observers) {
      await observer(ctx);
    }
    final type = ctx.type;
    // `system` rows are written locally (G) and rendered as trusted group /
    // identity events. A peer must never be able to inject one, so a
    // received `system` is dropped instead of stored like unknown content.
    if (type == MessageTypes.system) return const Ignored();
    final handler = _handlers[type];
    if (handler != null) return handler.handle(ctx);
    if (isControlPayload(ctx.payload)) return const Ignored();
    return ContentMessageHandler.unknown.handle(ctx);
  }
}
