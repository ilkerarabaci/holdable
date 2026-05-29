import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Crash reporting seam. Alpha ships a no-op implementation so the app builds
/// and runs without a Firebase project. When Firebase Crashlytics is
/// configured (`flutterfire configure` → google-services.json / plist), add a
/// `FirebaseCrashReporter implements CrashReporter` and override
/// [crashReporterProvider] + the instance created in `main`.
abstract class CrashReporter {
  void recordError(Object error, StackTrace? stack, {bool fatal});
  void recordFlutterError(FlutterErrorDetails details);
}

/// Default: logs in debug, swallows in release. No network, no dependencies.
class NoopCrashReporter implements CrashReporter {
  const NoopCrashReporter();

  @override
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) {
    if (kDebugMode) {
      debugPrint('[crash${fatal ? ':fatal' : ''}] $error');
    }
  }

  @override
  void recordFlutterError(FlutterErrorDetails details) {
    FlutterError.presentError(details);
  }
}

final crashReporterProvider =
    Provider<CrashReporter>((ref) => const NoopCrashReporter());
