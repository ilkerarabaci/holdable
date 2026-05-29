import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/theme_controller.dart';
import 'shared/crash/crash_reporter.dart';

Future<void> main() async {
  // Alpha crash reporting is a no-op until Firebase Crashlytics is configured
  // (see CrashReporter). runZonedGuarded + FlutterError.onError route both
  // framework and uncaught async errors through the single seam.
  const CrashReporter reporter = NoopCrashReporter();

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = reporter.recordFlutterError;

    final prefs = await SharedPreferences.getInstance();

    runApp(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          crashReporterProvider.overrideWithValue(reporter),
        ],
        child: const HoldableApp(),
      ),
    );
  }, (error, stack) => reporter.recordError(error, stack, fatal: true));
}
