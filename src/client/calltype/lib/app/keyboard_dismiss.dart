import 'package:flutter/widgets.dart';

/// App-wide ways to put the on-screen keyboard away, which iOS does not
/// offer on its own (there is no "hide keyboard" key on the iPhone layout):
///
/// * dragging any scroll view (chat, lists, sheets) dismisses it, like
///   Messages / WhatsApp;
/// * a tap outside the focused text field unfocuses it. Flutter does this
///   only for mouse taps on mobile; a touch tap is added here.
///
/// A tap still reaches whatever was tapped (the unfocus happens on pointer
/// down and does not consume the event). Widgets that belong to a text
/// field, such as the composer's send and attach buttons, are wrapped in a
/// `TextFieldTapRegion` so tapping them keeps the keyboard up.
class KeyboardDismiss extends StatelessWidget {
  const KeyboardDismiss({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{
      EditableTextTapOutsideIntent:
          CallbackAction<EditableTextTapOutsideIntent>(
            onInvoke: (intent) {
              intent.focusNode.unfocus();
              return null;
            },
          ),
    },
    // Keeps the inherited behavior (scrollbars, physics, drag devices) and
    // only changes scroll views that do not set their own dismissal.
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      ),
      child: child,
    ),
  );
}
