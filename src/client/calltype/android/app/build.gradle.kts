import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// google-services.json is materialized from a GitHub secret only in release
// workflows (.github/scripts/firebase-config.sh); dev and CI sanity builds
// have none and must still compile. Why the file at all when the Dart-side
// FirebaseOptions already initialize Firebase: an FCM message that starts a
// killed process needs the default FirebaseApp from native resources first.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Upload key (Play App Signing re-signs for devices). CI passes env vars
// (JAY_ANDROID_KEYSTORE_PATH, _STORE_PASSWORD, _KEY_ALIAS, _KEY_PASSWORD, see
// .github/workflows/_release-android.yml); locally a git-ignored
// android/key.properties with storeFile/storePassword/keyAlias/keyPassword
// works the same way. Env wins so a stray local file cannot sign a CI build.
val keyProps =
    Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }

fun signingValue(prop: String, env: String): String? =
    System.getenv(env)?.takeIf { it.isNotEmpty() } ?: keyProps.getProperty(prop)

val uploadStoreFile = signingValue("storeFile", "JAY_ANDROID_KEYSTORE_PATH")

// Set by release workflows: a release build without the upload key must FAIL
// there instead of silently producing a debug-signed AAB that Play rejects
// (or, worse, that someone distributes).
val requireReleaseSigning = System.getenv("JAY_REQUIRE_RELEASE_SIGNING") == "true"

android {
    // Same identifier as iOS/macOS (cz.zcloud.jay). The applicationId is
    // immutable after the first Play upload; the Kotlin package follows it.
    namespace = "cz.zcloud.jay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (>= 10) uses java.time APIs that are
        // missing below API 26; desugaring backports them for minSdk 24.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Must match the iOS/macOS bundle id; immutable after the first Play
        // upload (Firebase app registration and assetlinks.json key on it).
        applicationId = "cz.zcloud.jay"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (uploadStoreFile != null) {
            create("upload") {
                storeFile = file(uploadStoreFile)
                storePassword = signingValue("storePassword", "JAY_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "JAY_ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "JAY_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                when {
                    uploadStoreFile != null -> signingConfigs.getByName("upload")
                    requireReleaseSigning ->
                        throw GradleException(
                            "Release signing required (JAY_REQUIRE_RELEASE_SIGNING=true) " +
                                "but no upload key configured (JAY_ANDROID_KEYSTORE_PATH / key.properties).",
                        )
                    else -> {
                        // `flutter run --release` and ci.yml sanity builds:
                        // debug-signed, installable locally, never for Play.
                        logger.warn("Jay: no upload key configured, release builds are DEBUG-signed.")
                        signingConfigs.getByName("debug")
                    }
                }
            // R8 + resource shrinking, stated explicitly: the Flutter Gradle
            // plugin enables them for release today (3.41), but that default
            // has changed between versions and our keep rules
            // (proguard-rules.pro, res/raw/keep.xml) only matter while it is on.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Version from the flutter_local_notifications 22.x README.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
