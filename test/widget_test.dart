import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drift/native.dart';
import 'package:holdable/app/app.dart';
import 'package:holdable/app/router.dart';
import 'package:holdable/app/theme_controller.dart';
import 'package:holdable/features/library/data/app_database.dart';
import 'package:holdable/features/library/data/library_controller.dart';
import 'package:holdable/features/library/domain/library_model.dart';
import 'package:holdable/features/library/presentation/model_card.dart';
import 'package:holdable/features/import/data/import_service.dart';
import 'package:holdable/features/import/data/sample_models.dart';
import 'package:holdable/features/onboarding/data/onboarding_controller.dart';
import 'package:holdable/shared/crash/crash_reporter.dart';
import 'package:holdable/shared/utils/format.dart';
import 'package:shared_preferences/shared_preferences.dart';

LibraryModel _sample(String id, String name, {DateTime? at}) => LibraryModel(
      id: id,
      name: name,
      format: ModelFormat.stl,
      sizeBytes: 52428800,
      filePath: '/tmp/$id.stl',
      importedAt: at ?? DateTime(2026, 1, 1),
    );

/// Seeds the library with fixed models for widget tests.
class _SeededLibrary extends LibraryController {
  _SeededLibrary(this._seed);
  final List<LibraryModel> _seed;
  @override
  List<LibraryModel> build() => _seed;
}

/// A fresh in-memory Drift database for a test (no on-device file).
AppDatabase _memDb(Ref ref) {
  final db = AppDatabase(NativeDatabase.memory());
  ref.onDispose(db.close);
  return db;
}

Future<ProviderContainer> _container(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWith(_memDb),
    ],
  );
}

Future<void> _pumpApp(
  WidgetTester tester,
  Map<String, Object> seed, {
  List<LibraryModel>? library,
}) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWith(_memDb),
        // Skip the cold-start splash so these tests land on their screen.
        splashEnabledProvider.overrideWithValue(false),
        if (library != null)
          libraryControllerProvider.overrideWith(() => _SeededLibrary(library)),
      ],
      child: const HoldableApp(bootstrapSharing: false),
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
    expect(
        find.text('Drop an .obj, .stl, .glb, .gltf, .ply,\n'
            '.3mf, .off, .dae, .3ds or .fbx to begin.'),
        findsOneWidget);
  });

  testWidgets('splash plays then hands off to the library (PO #1)',
      (tester) async {
    // splashEnabledProvider keeps its true default here (unlike _pumpApp), so
    // the app opens on the brand splash before routing onward.
    SharedPreferences.setMockInitialValues({'onboarding_shown': true});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWith(_memDb),
        ],
        child: const HoldableApp(bootstrapSharing: false),
      ),
    );
    await tester.pump(); // first frame: the splash wordmark
    expect(find.text('Holdable'), findsOneWidget);
    expect(find.text('Your shelf is empty.'), findsNothing);
    await tester.pumpAndSettle(); // play the one-shot animation, then navigate
    expect(find.text('Your shelf is empty.'), findsOneWidget);
  });

  testWidgets('library header exposes a theme toggle', (tester) async {
    await _pumpApp(tester, {'onboarding_shown': true});
    expect(find.byTooltip('Light mode'), findsOneWidget); // dark default
  });

  testWidgets('FAB opens the import sheet with Files/URL/Sample',
      (tester) async {
    await _pumpApp(tester, {'onboarding_shown': true});
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Add a model'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('From URL'), findsOneWidget);
    expect(find.text('Sample models'), findsOneWidget);
  });

  testWidgets('seeded library renders model cards, not the empty state',
      (tester) async {
    await _pumpApp(
      tester,
      {'onboarding_shown': true},
      library: [_sample('a', 'Bracket'), _sample('b', 'Vase')],
    );
    expect(find.text('Your shelf is empty.'), findsNothing);
    expect(find.byType(ModelCard), findsNWidgets(2));
    expect(find.text('Bracket'), findsOneWidget);
    expect(find.textContaining('.STL'), findsWidgets);
  });

  testWidgets('long-press -> Rename dialog updates the card', (tester) async {
    await _pumpApp(
      tester,
      {'onboarding_shown': true},
      library: [_sample('a', 'Bracket')],
    );
    await tester.longPress(find.byType(ModelCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Bracket v2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Bracket v2'), findsOneWidget);
    expect(find.text('Bracket'), findsNothing);
  });

  test('LibraryController add/rename/remove persists to Drift', () async {
    final c = await _container({});
    addTearDown(c.dispose);
    final n = c.read(libraryControllerProvider.notifier);
    await n.add(_sample('a', 'Bracket', at: DateTime(2026, 1, 1)));
    await n.add(_sample('b', 'Vase', at: DateTime(2026, 1, 2)));
    expect(c.read(libraryControllerProvider).length, 2);
    await n.rename('a', 'Bracket v2');
    expect(c.read(libraryControllerProvider).first.name, 'Vase'); // newest first
    await n.remove('b');
    expect(c.read(libraryControllerProvider).single.name, 'Bracket v2');

    // Persistence: a fresh controller on the SAME db hydrates the survivor.
    final rows = await c.read(databaseProvider).allModels();
    expect(rows.single.name, 'Bracket v2');

    await n.setThumbnail('a', '/thumbs/a.png');
    expect(c.read(libraryControllerProvider).single.thumbnailPath, '/thumbs/a.png');
    final rows2 = await c.read(databaseProvider).allModels();
    expect(rows2.single.thumbnailPath, '/thumbs/a.png');
  });

  test('ModelFormat.fromExtension accepts obj/stl, rejects blend', () {
    expect(ModelFormat.fromExtension('obj'), ModelFormat.obj);
    expect(ModelFormat.fromExtension('.STL'), ModelFormat.stl);
    expect(ModelFormat.fromExtension('blend'), isNull);
  });

  test('bytesToHuman formats sizes', () {
    expect(bytesToHuman(512), '512 B');
    expect(bytesToHuman(1536), '1.5 KB');
    expect(bytesToHuman(52428800), '50.0 MB');
  });

  test('share intent keeps native + convertible model paths, drops the rest',
      () {
    final kept = ImportService.supportedPaths([
      '/in/cube.obj',
      '/in/bracket.STL',
      '/in/notes.pdf',
      '/in/scene.blend', // convertible (handled by the conversion service)
      '/in/photo.png',
    ]);
    // .blend is now kept (routed to the conversion service); .pdf/.png are not.
    expect(kept, ['/in/cube.obj', '/in/bracket.STL', '/in/scene.blend']);
  });

  test('sample catalog is non-empty and all .stl/.obj', () {
    expect(kSampleModels, isNotEmpty);
    for (final s in kSampleModels) {
      expect(s.asset, startsWith('assets/sample_models/'));
      expect(ModelFormat.fromExtension(s.asset.split('.').last), isNotNull);
    }
  });

  test('NoopCrashReporter records without throwing', () {
    const reporter = NoopCrashReporter();
    expect(
      () => reporter.recordError(StateError('boom'), StackTrace.current),
      returnsNormally,
    );
  });
}
