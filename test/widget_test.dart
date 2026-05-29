import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:holdable/app/app.dart';
import 'package:holdable/app/theme_controller.dart';
import 'package:holdable/features/onboarding/data/onboarding_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

Future<void> _pumpApp(WidgetTester tester, Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const HoldableApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  // Avoid real network font fetches during tests; fall back to bundled.
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('theme defaults to dark', () async {
    final c = await _container({});
    addTearDown(c.dispose);
    expect(c.read(themeControllerProvider), ThemeMode.dark);
  });

  test('theme toggle flips dark -> light', () async {
    final c = await _container({});
    addTearDown(c.dispose);
    await c.read(themeControllerProvider.notifier).toggle();
    expect(c.read(themeControllerProvider), ThemeMode.light);
  });

  test('onboarding flag defaults false then markShown persists true', () async {
    final c = await _container({});
    addTearDown(c.dispose);
    expect(c.read(onboardingShownProvider), false);
    await c.read(onboardingShownProvider.notifier).markShown();
    expect(c.read(onboardingShownProvider), true);
  });

  testWidgets('first launch shows onboarding', (tester) async {
    await _pumpApp(tester, {});
    expect(find.text('Enter studio'), findsOneWidget);
  });

  testWidgets('returning user lands on empty library', (tester) async {
    await _pumpApp(tester, {'onboarding_shown': true});
    expect(find.text('Your shelf is empty.'), findsOneWidget);
    expect(find.text('Drop a .obj or .stl to begin.'), findsOneWidget);
  });

  testWidgets('library header exposes a theme toggle', (tester) async {
    await _pumpApp(tester, {'onboarding_shown': true});
    expect(find.byTooltip('Light mode'), findsOneWidget); // dark default
  });
}
