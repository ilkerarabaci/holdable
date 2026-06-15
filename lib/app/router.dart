import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/library/domain/library_model.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/onboarding/data/onboarding_controller.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/viewer/presentation/viewer_screen.dart';

class Routes {
  Routes._();
  static const splash = '/splash';
  static const onboarding = '/onboarding';
  static const library = '/library';
  static const settings = '/settings';
  static const viewer = '/viewer';
}

/// Whether the cold-start brand splash (PO #1) runs. Production = true; widget
/// tests override it to false so they pump straight to the screen under test
/// (the splash's timed hand-off would otherwise leave a pending animation).
final splashEnabledProvider = Provider<bool>((ref) => true);

/// App router. The onboarding gate is the INITIAL location (computed from the
/// persisted flag) rather than a global `redirect` — a top-level redirect runs
/// on every navigation and was swallowing imperative pops, trapping the user
/// in pushed routes (e.g. the viewer). No redirect = clean push/pop. With the
/// splash enabled the app opens on it, and SplashScreen routes onward to the
/// onboarding gate / library once its animation finishes.
final routerProvider = Provider<GoRouter>((ref) {
  final shown = ref.read(onboardingShownProvider);
  final splash = ref.read(splashEnabledProvider);
  return GoRouter(
    initialLocation: splash
        ? Routes.splash
        : (shown ? Routes.library : Routes.onboarding),
    routes: [
      GoRoute(
        path: Routes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
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
        builder: (context, state) =>
            ViewerScreen(model: state.extra as LibraryModel),
      ),
    ],
  );
});
