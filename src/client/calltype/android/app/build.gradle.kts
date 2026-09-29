plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
