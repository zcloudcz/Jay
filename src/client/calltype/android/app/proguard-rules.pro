# R8 keep rules for the Jay release build (stream P, P4).
# Most plugins ship consumer rules of their own; the ones below are repeated
# on purpose because a missing class shows up only at runtime on a device
# (a call that never connects, a notification that never shows), never in CI.
# Streams C and N append rules for their native code here.

# flutter_webrtc: JNI + reflection into org.webrtc; stripping it breaks calls
# at runtime only. (Also in the plugin's consumer rules, kept here explicitly.)
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }

# flutter_callkit_incoming (stream C): its README requires this rule; it
# (de)serializes call data by reflection and obfuscated keys break it.
-keep class com.hiennv.flutter_callkit_incoming.** { *; }

# Flutter deferred components reference Play Core; Jay does not use them,
# so the missing classes are expected and not an error.
-dontwarn com.google.android.play.core.**
