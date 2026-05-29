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

  testWidgets('first launch shows onboarding (Continue, not Enter studio)',
      (tester) async {
    await _pumpApp(tester, {});
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Enter studio'), findsNothing);
  });

  testWidgets('onboarding advertises .obj/.stl, never .blend', (tester) async {
    await _pumpApp(tester, {});
    // Page 2 carries the format chips.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('.OBJ'), findsOneWidget);
    expect(find.text('.STL'), findsOneWidget);
    expect(find.textContaining('more formats soon'), findsOneWidget);
    expect(find.textContaining('.blend'), findsNothing);
  });

  testWidgets('reaching last pane shows Enter studio; tapping enters library',
      (tester) async {
    await _pumpApp(tester, {});
    await tester.tap(find.text('Continue')); // -> pane 2
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue')); // -> pane 3
    await tester.pumpAndSettle();
    expect(find.text('Enter studio'), findsOneWidget);
    await tester.tap(find.text('Enter studio'));
    await tester.pumpAndSettle();
    expect(find.text('Your shelf is empty.'), findsOneWidget);
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
