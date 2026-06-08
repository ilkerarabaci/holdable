plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.holdable"
    // flutter_plugin_android_lifecycle (via file_picker) requires compileSdk 36;
    // pin it (matches the installed SDK platform) instead of flutter's default.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.holdable"
        // AR-1 spike (ADR-003): ar_flutter_plugin_2 (ARCore + arsceneview) sets
        // minSdkVersion 28, so the app floor rises to Android 9. Product note:
        // this drops Android 8 and below — acceptable given current install base.
        minSdk = maxOf(28, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Package only arm64 native libs. `flutter build --target-platform
        // android-arm64` slims Flutter's own libs but the plugin .so files
        // (thermion + arsceneview Filament, ARCore) were still bundled for all 3
        // ABIs (~85MB). abiFilters drops armeabi-v7a + x86_64 (every real target
        // is arm64) → ~half again. Play distribution should use an AAB instead.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        // Override the per-machine default debug key with a committed, stable
        // debug keystore (standard public "android" credentials — no security
        // value). This keeps the debug signature identical across CI builds, so
        // sideloaded test-device updates install over the previous build instead
        // of forcing an uninstall + Play Protect re-approval every time.
        getByName("debug") {
            storeFile = file("holdable-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
