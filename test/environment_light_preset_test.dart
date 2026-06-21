import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/presentation/environment_backdrop.dart';
import 'package:holdable/features/viewer/presentation/scene_view.dart';

/// Faz C / PO #6: the environment → light-preset mapping is a pure function
/// (no Filament/GPU), so its contract can be asserted here without a device.
void main() {
  test('none is the neutral identity (no scale, bias or IBL)', () {
    final p = environmentLightPreset(AppEnvironment.none);
    expect(p.intensityScale, 1.0);
    expect(p.azimuthBias, 0.0);
    expect(p.iblAmount, 0.0);
  });

  test('cafe swings the key (positive bias) and uses no IBL', () {
    final p = environmentLightPreset(AppEnvironment.cafe);
    expect(p.azimuthBias, greaterThan(0.0));
    expect(p.iblAmount, 0.0);
  });

  test('sky adds a soft IBL and a brighter rig', () {
    final p = environmentLightPreset(AppEnvironment.sky);
    expect(p.iblAmount, greaterThan(0.0));
    expect(p.intensityScale, greaterThan(1.0));
    expect(p.azimuthBias, 0.0);
  });

  test('studio has the highest intensity scale and a positive IBL', () {
    final studio = environmentLightPreset(AppEnvironment.studio);
    expect(studio.iblAmount, greaterThan(0.0));
    // Brightest rig of any environment.
    for (final env in AppEnvironment.values) {
      expect(
        studio.intensityScale,
        greaterThanOrEqualTo(environmentLightPreset(env).intensityScale),
        reason: 'studio should be at least as bright as $env',
      );
    }
    // And strictly brighter than the neutral baseline.
    expect(studio.intensityScale,
        greaterThan(environmentLightPreset(AppEnvironment.none).intensityScale));
  });
}
