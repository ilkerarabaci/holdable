import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/presentation/scene_view.dart';

/// The AR colour-bake DECISION (Faz D / #10): which colour `_openAr` hands the
/// GLB exporter. The actual bake (decision → glTF baseColorFactor) is covered in
/// glb_exporter_test; this pins the picked-vs-fallback decision so a regression
/// where the user's colour silently stops reaching AR is caught in CI, not on
/// the device.
void main() {
  group('arPickedColorArgb', () {
    const red = 0xFFFF0000;

    test('uses the picked colour when one is chosen and no texture shows', () {
      expect(
        arPickedColorArgb(colorPicked: true, hasTexture: false, baseColorArgb: red),
        red,
      );
    });

    test('returns null when no colour was picked (caller falls back to the '
        'model\'s own colour)', () {
      expect(
        arPickedColorArgb(colorPicked: false, hasTexture: false, baseColorArgb: red),
        isNull,
      );
    });

    test('returns null while a texture is showing (AR export is untextured)', () {
      expect(
        arPickedColorArgb(colorPicked: true, hasTexture: true, baseColorArgb: red),
        isNull,
      );
    });
  });
}
