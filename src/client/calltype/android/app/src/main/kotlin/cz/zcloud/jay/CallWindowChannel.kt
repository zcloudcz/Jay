package cz.zcloud.jay

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine

/**
 * MethodChannel `jay/call_window`: `setShowWhenLocked(bool)` and
 * `isKeyguardLocked()` for answering a call over the phone's lock screen.
 *
 * Wave-0 stub (gap-calls §5.4): registers nothing yet, so the Dart side gets
 * MissingPluginException until stream C (C06) fills in the body. It exists
 * now so MainActivity — owned by C from wave 1 — already has its only hook.
 */
object CallWindowChannel {
    @Suppress("UNUSED_PARAMETER")
    fun register(flutterEngine: FlutterEngine, activity: Activity) {
    }
}
