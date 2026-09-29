import 'package:calltype/features/chat/active_conversation.dart';
import 'package:calltype/features/chat/chat_extensions.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Wave-0 seams of contract M §4.5. Streams M, N and M2 build on them; these
// tests pin the behavior they rely on before any of them lands.
void main() {
  group('ActiveConversation', () {
    test('starts with no open conversation and notifies on change', () {
      final active = ActiveConversation(
        lifecycleState: () => AppLifecycleState.resumed,
      );
      final seen = <String?>[];
      active.addListener(() => seen.add(active.value));

      expect(active.value, isNull);
      active.value = 'conv-1';
      active.value = null;
      expect(seen, ['conv-1', null]);
    });

    test('appInForeground follows the app lifecycle', () {
      AppLifecycleState? state = AppLifecycleState.resumed;
      final active = ActiveConversation(lifecycleState: () => state);
      expect(active.appInForeground, isTrue);

      // N must still notify for the open chat once the app is not visible.
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        state = s;
        expect(active.appInForeground, isFalse, reason: '$s');
      }

      state = null; // before the binding reports anything (first frame)
      expect(active.appInForeground, isTrue);
    });
  });

  test('ChatExtensions.none adds nothing', () {
    expect(ChatExtensions.none.types, isEmpty);
    expect(ChatExtensions.none.attachmentActions, isEmpty);
    expect(ChatExtensions.none.trailingWhenEmpty, isNull);
  });
}
