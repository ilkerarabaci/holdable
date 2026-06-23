import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/import_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #4 restart-resume. Covers the persistence-read + clear paths of
// resumePendingConversion that return BEFORE any network call (nothing pending,
// or a corrupt record) — so the suite needs no mock server. The full resume
// (poll → download → import) is verified on-device by kill-mid-convert/restart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'holdable_pending_conversion_v1';

  test('resume is a no-op (null) when nothing is pending', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final result =
        await c.read(importServiceProvider).resumePendingConversion();
    expect(result, isNull);
  });

  test('resume ignores AND clears a corrupt pending record', () async {
    SharedPreferences.setMockInitialValues({key: 'not-valid-json'});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final result =
        await c.read(importServiceProvider).resumePendingConversion();
    expect(result, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), isNull,
        reason: 'a corrupt record must be cleared so it cannot wedge startup');
  });
}
