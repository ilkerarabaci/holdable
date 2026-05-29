import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/library/domain/library_model.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/onboarding/data/onboarding_controller.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/viewer/presentation/viewer_screen.dart';

class Routes {
  Routes._();
  static const onboarding = '/onboarding';
  static const library = '/library';
  static const settings = '/settings';
  static const viewer = '/viewer';
}

/// App router. Redirects to onboarding on first launch, then to the library.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.library,
    redirect: (context, state) {
      final shown = ref.read(onboardingShownProvider);
      final atOnboarding = state.matchedLocation == Routes.onboarding;
      String? to;
      if (!shown && !atOnboarding) {
        to = Routes.onboarding;
      } else if (shown && atOnboarding) {
        to = Routes.library;
      }
      debugPrint('[holdable-nav] redirect loc=${state.matchedLocation} uri=${state.uri} -> ${to ?? "null"}');
      return to;
    },
    routes: [
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: Routes.library,
        builder: (context, state) => const LibraryScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.viewer,
        builder: (context, state) {
          debugPrint('[holdable-nav] viewer builder extra=${state.extra.runtimeType}');
          return ViewerScreen(model: state.extra as LibraryModel);
        },
      ),
    ],
  );
});
