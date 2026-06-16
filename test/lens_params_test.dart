import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/presentation/scene_view.dart';

/// Faz B #9: the lens-preset → projection-params mapping is a pure function
/// (no Filament/GPU), so its contract can be asserted here without a device.
void main() {
  test('70mm is the default perspective lens', () {
    final p = lensParamsFor('70mm');
    expect(p.focalLength, 70);
    expect(p.fovDegrees, isNull);
    expect(p.ortho, isFalse);
  });

  test('24mm is a wide perspective lens', () {
    final p = lensParamsFor('24mm');
    expect(p.focalLength, 24);
    expect(p.fovDegrees, isNull);
    expect(p.ortho, isFalse);
  });

  test('fisheye is an ultra-wide vertical FoV (not a focal length)', () {
    final p = lensParamsFor('fisheye');
    expect(p.focalLength, isNull);
    expect(p.fovDegrees, 120);
    expect(p.ortho, isFalse);
  });

  test('ortho selects the orthographic projection', () {
    final p = lensParamsFor('ortho');
    expect(p.ortho, isTrue);
    expect(p.focalLength, isNull);
    expect(p.fovDegrees, isNull);
  });

  test('an unknown preset falls back to the 70mm default', () {
    final p = lensParamsFor('nonsense');
    expect(p.focalLength, 70);
    expect(p.fovDegrees, isNull);
    expect(p.ortho, isFalse);
  });

  test('exactly one projection mode is selected per preset', () {
    for (final preset in const ['70mm', '24mm', 'fisheye', 'ortho', 'x']) {
      final p = lensParamsFor(preset);
      final modes = [
        p.focalLength != null,
        p.fovDegrees != null,
        p.ortho,
      ].where((selected) => selected).length;
      expect(modes, 1, reason: 'preset "$preset" must pick one projection');
    }
  });
}
