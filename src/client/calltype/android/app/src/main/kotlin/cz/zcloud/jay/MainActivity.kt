package cz.zcloud.jay

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity (not FlutterActivity) because local_auth's
// biometric prompt needs a FragmentActivity host.
//
// No static android:showWhenLocked in the manifest on purpose: that would show
// the whole app — chats included — over the phone's lock screen. The call UI
// turns it on only for the duration of a call via CallWindowChannel (stream C).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // super registers the generated plugins; keep it first.
        super.configureFlutterEngine(flutterEngine)
        CallWindowChannel.register(flutterEngine, this)
    }
}
