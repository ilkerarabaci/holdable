import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/heightmap_converter.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';

/// Builds a solid w×h RGBA image filled with one grey level.
Uint8List _solid(int w, int h, int grey) {
  final b = Uint8List(w * h * 4);
  for (var i = 0; i < b.length; i += 4) {
    b[i] = grey;
    b[i + 1] = grey;
    b[i + 2] = grey;
    b[i + 3] = 255;
  }
  return b;
}

void main() {
  group('heightmapToStl', () {
    test('emits a parseable binary STL with the expected triangle count', () {
      // 4×4 image, gridMax default → grid is 4×4 nodes.
      final stl = heightmapToStl(rgba: _solid(4, 4, 128), imgW: 4, imgH: 4)!;
      // cells=9 → top 18 + bottom 18 + walls 2*(3+3)*2=24 = 60 triangles.
      const tris = 60;
      expect(stl.length, 84 + tris * 50);

      final mesh = ModelParser.parse(stl, format: 'stl');
      expect(mesh.triangleCount, tris);
      expect(mesh.vertexCount, tris * 3);
    });

    test('brighter pixels are taller by default; invert raises dark instead', () {
      const def = HeightmapParams(); // invert: false (default)
      final lightDef = ModelParser.parse(
          heightmapToStl(rgba: _solid(8, 8, 255), imgW: 8, imgH: 8, params: def)!,
          format: 'stl');
      final darkDef = ModelParser.parse(
          heightmapToStl(rgba: _solid(8, 8, 0), imgW: 8, imgH: 8, params: def)!,
          format: 'stl');
      // Default: the lit (bright) area rises, the dark area stays at the base.
      expect(lightDef.bounds.maxY, greaterThan(darkDef.bounds.maxY));
      expect(darkDef.bounds.maxY, closeTo(def.base, 0.01));
      expect(lightDef.bounds.maxY, closeTo(def.base + def.relief, 0.01));

      // Inverted: dark line art embosses upward instead.
      const inv = HeightmapParams(invert: true);
      final darkInv = ModelParser.parse(
          heightmapToStl(rgba: _solid(8, 8, 0), imgW: 8, imgH: 8, params: inv)!,
          format: 'stl');
      final lightInv = ModelParser.parse(
          heightmapToStl(rgba: _solid(8, 8, 255), imgW: 8, imgH: 8, params: inv)!,
          format: 'stl');
      expect(darkInv.bounds.maxY, greaterThan(lightInv.bounds.maxY));
    });

    test('base sits at y=0 (watertight solid, not a floating sheet)', () {
      final mesh = ModelParser.parse(
          heightmapToStl(rgba: _solid(6, 6, 90), imgW: 6, imgH: 6)!,
          format: 'stl');
      expect(mesh.bounds.minY, closeTo(0.0, 0.01));
    });

    test('returns null for a degenerate image', () {
      expect(heightmapToStl(rgba: _solid(1, 1, 0), imgW: 1, imgH: 1), isNull);
    });
  });
}
