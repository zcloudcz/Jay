import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (Google Play upload key). Read from android/key.properties
// (local builds, never committed) or from ANDROID_UPLOAD_* environment
// variables (CI). Without either, release builds fall back to the debug key so
// `flutter run --release` and the unsigned CI legs keep working; such a build
// cannot be uploaded to Play.
val uploadKey = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
    System.getenv("ANDROID_UPLOAD_KEYSTORE_FILE")?.let { setProperty("storeFile", it) }
    System.getenv("ANDROID_UPLOAD_KEYSTORE_PASSWORD")?.let {
        setProperty("storePassword", it)
        setProperty("keyPassword", it)
    }
    System.getenv("ANDROID_UPLOAD_KEY_ALIAS")?.let { setProperty("keyAlias", it) }
}
val hasUploadKey = listOf("storeFile", "storePassword", "keyPassword", "keyAlias")
    .all { !uploadKey.getProperty(it).isNullOrBlank() }

android {
    namespace = "cz.zcloud.jay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs core library desugaring (its
        // README, Android Gradle setup), even without scheduled notifications.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "cz.zcloud.jay"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = file(uploadKey.getProperty("storeFile"))
                storePassword = uploadKey.getProperty("storePassword")
                keyAlias = uploadKey.getProperty("keyAlias")
                keyPassword = uploadKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasUploadKey) "upload" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// FCM (notifications spec 2026-11-06, section 2): the Google services plugin
// turns google-services.json into the resources Firebase.initializeApp()
// reads. The file only exists once the Firebase project does (CI writes it
// from the optional GOOGLE_SERVICES_JSON_BASE64 secret), and the plugin
// fails the build without it, so it is applied only when the file is there.
// Without it the app builds, Firebase init fails at runtime and the app
// reports push as "not configured" while local notifications keep working.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
