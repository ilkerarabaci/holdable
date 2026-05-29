import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme_controller.dart';

/// Tracks whether onboarding has been shown (drop on first launch only).
class OnboardingController extends Notifier<bool> {
  static const _key = 'onboarding_shown';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(_key) ?? false;

  Future<void> markShown() async {
    state = true;
    await ref.read(sharedPreferencesProvider).setBool(_key, true);
  }
}

final onboardingShownProvider =
    NotifierProvider<OnboardingController, bool>(OnboardingController.new);
