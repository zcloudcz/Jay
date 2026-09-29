/// Entry point for call pushes (contracts K6, calls plan KC7).
///
/// Called by stream N's FCM handlers — in the foreground AND from the
/// background isolate — for `data['type']` in `{'call', 'call_cancel'}`.
/// Stream C implements the body in C06/C07 (show the native incoming-call UI,
/// or end it on `call_cancel`).
///
/// WHY a top-level function and not a class behind a Provider: the FCM
/// background isolate starts without the widget tree or any DI, so the only
/// thing it can reach is a top-level symbol. `@pragma('vm:entry-point')`
/// keeps the AOT compiler from tree-shaking it, because in a release build
/// nothing in the main isolate appears to call it.
///
/// Wave-0 stub: ignores the push. Until C06 lands a call push therefore does
/// nothing more than today — the caller still sees the offer delivered when
/// the callee connects.
@pragma('vm:entry-point')
Future<void> handleCallPush(Map<String, dynamic> data) async {}
