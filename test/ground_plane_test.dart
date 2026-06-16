import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/presentation/scene_view.dart';

/// Faz B #4: the shadow-catcher quad geometry is built by a pure function, so
/// its shape can be verified here without a Filament/GPU context.
void main() {
  test('builds a 4-vertex quad with 2 triangles', () {
    final g = buildGroundPlane(y: -1.0, half: 4.0);
    expect(g.positions.length, 4 * 3); // 4 verts × xyz
    expect(g.normals.length, 4 * 3);
    expect(g.indices.length, 6); // 2 triangles
  });

  test('all vertices sit at the requested height', () {
    final g = buildGroundPlane(y: -1.0, half: 4.0);
    for (var v = 0; v < 4; v++) {
      expect(g.positions[v * 3 + 1], -1.0, reason: 'vertex $v y');
    }
  });

  test('the quad spans ±half in x and z', () {
    const half = 4.0;
    final g = buildGroundPlane(y: -1.0, half: half);
    double minX = double.infinity, maxX = -double.infinity;
    double minZ = double.infinity, maxZ = -double.infinity;
    for (var v = 0; v < 4; v++) {
      final x = g.positions[v * 3];
      final z = g.positions[v * 3 + 2];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
    expect(minX, -half);
    expect(maxX, half);
    expect(minZ, -half);
    expect(maxZ, half);
  });

  test('every normal points straight up (+Y)', () {
    final g = buildGroundPlane(y: -1.0, half: 4.0);
    for (var v = 0; v < 4; v++) {
      expect(g.normals[v * 3], 0.0);
      expect(g.normals[v * 3 + 1], 1.0);
      expect(g.normals[v * 3 + 2], 0.0);
    }
  });

  test('indices reference only the four defined vertices', () {
    final g = buildGroundPlane(y: -1.0, half: 4.0);
    for (final i in g.indices) {
      expect(i, inInclusiveRange(0, 3));
    }
  });
}
