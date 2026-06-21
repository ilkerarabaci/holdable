import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/presentation/scene_view.dart';

/// Efe feedback #3: the ground-shadow sun must stay CONSISTENT with the
/// lighting — it points along the dominant key light (rotated by the composed
/// rig azimuth) and its strength tracks the light intensity. Both are pure
/// functions, so the contract is asserted here without a Filament/GPU context.
void main() {
  group('groundShadowSunDirection', () {
    test('returns a unit vector', () {
      final d = groundShadowSunDirection(
          keyX: 0.3, keyY: -0.8, keyZ: 0.5, azimuth: 0.0);
      final len = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
      expect(len, closeTo(1.0, 1e-9));
    });

    test('at azimuth 0 it points along the (normalized) key direction', () {
      // The rig key sun is (0.3, -0.8, 0.5); aiming the shadow sun along it
      // makes the shadow fall away from the key.
      final d = groundShadowSunDirection(
          keyX: 0.3, keyY: -0.8, keyZ: 0.5, azimuth: 0.0);
      final len = math.sqrt(0.3 * 0.3 + 0.8 * 0.8 + 0.5 * 0.5);
      expect(d.x, closeTo(0.3 / len, 1e-9));
      expect(d.y, closeTo(-0.8 / len, 1e-9));
      expect(d.z, closeTo(0.5 / len, 1e-9));
    });

    test('keeps a downward (negative-Y) tilt so the shadow lands below', () {
      for (final az in [0.0, 0.6, math.pi / 2, math.pi, -1.0]) {
        final d = groundShadowSunDirection(
            keyX: 0.3, keyY: -0.8, keyZ: 0.5, azimuth: az);
        expect(d.y, lessThan(0.0), reason: 'azimuth $az should still aim down');
      }
    });

    test('rotating the azimuth swings the horizontal direction (tracks the '
        'light angle)', () {
      final base = groundShadowSunDirection(
          keyX: 0.3, keyY: -0.8, keyZ: 0.5, azimuth: 0.0);
      final swung = groundShadowSunDirection(
          keyX: 0.3, keyY: -0.8, keyZ: 0.5, azimuth: math.pi / 2);
      // Y (tilt) is unchanged by a Y-axis rotation; X/Z must move.
      expect(swung.y, closeTo(base.y, 1e-9));
      expect((swung.x - base.x).abs() + (swung.z - base.z).abs(),
          greaterThan(0.1));
    });

    test('a degenerate (zero) key falls back to straight down', () {
      final d = groundShadowSunDirection(
          keyX: 0.0, keyY: 0.0, keyZ: 0.0, azimuth: 1.0);
      expect(d.x, 0.0);
      expect(d.y, -1.0);
      expect(d.z, 0.0);
    });
  });

  group('groundShadowSunIntensity', () {
    test('scales up with the light intensity multiplier', () {
      final dim =
          groundShadowSunIntensity(lightIntensity: 0.5, envIntensityScale: 1.0);
      final bright =
          groundShadowSunIntensity(lightIntensity: 2.0, envIntensityScale: 1.0);
      expect(bright, greaterThan(dim));
    });

    test('a brighter environment scale brightens the shadow sun', () {
      final neutral =
          groundShadowSunIntensity(lightIntensity: 1.0, envIntensityScale: 1.0);
      final studio = groundShadowSunIntensity(
          lightIntensity: 1.0, envIntensityScale: 1.25);
      expect(studio, greaterThan(neutral));
    });

    test('clamps so a very dim or very bright rig stays readable', () {
      final tiny = groundShadowSunIntensity(
          lightIntensity: 0.01, envIntensityScale: 0.1);
      final huge = groundShadowSunIntensity(
          lightIntensity: 100.0, envIntensityScale: 100.0);
      expect(tiny, greaterThanOrEqualTo(20000.0));
      expect(huge, lessThanOrEqualTo(120000.0));
    });
  });
}
