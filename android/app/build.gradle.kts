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
        // NB: no `ndk.abiFilters` here — it conflicts with the CI's
        // `flutter build apk --split-per-abi` ("abiFilters cannot be present
        // when splits abi filters are set"). --split-per-abi already emits a
        // single-ABI (arm64) APK; that's where the slimming happens.
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

dependencies {
    // F4 hand-tracking POC: native camera + on-device hand-landmark inference.
    // CameraX drives the back camera (preview into a Flutter texture +
    // ImageAnalysis frames); MediaPipe Tasks Vision runs HandLandmarker on each
    // frame and we stream the 21 landmarks/hand up to Dart. See HandTracker.kt.
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("com.google.mediapipe:tasks-vision:0.10.14")
}

flutter {
    source = "../.."
}
