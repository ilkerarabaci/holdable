import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/presentation/scene_view.dart';
import 'package:vector_math/vector_math_64.dart';

/// Faz B #8: the CPU pivot ray-cast core is pure, so the Möller–Trumbore
/// intersection and the nearest-triangle search can be verified here without a
/// Filament/GPU context (mirrors ground_plane_test / thumbnail_raster_test).
void main() {
  group('rayTriangleIntersection', () {
    // A unit triangle in the z = 0 plane, spanning the XY origin corner.
    final v0 = Vector3(0, 0, 0);
    final v1 = Vector3(1, 0, 0);
    final v2 = Vector3(0, 1, 0);

    test('hits a triangle straight ahead and returns the distance', () {
      // Ray from z = +5 looking toward -z, aimed at a point inside the tri.
      final t = rayTriangleIntersection(
        Vector3(0.25, 0.25, 5),
        Vector3(0, 0, -1),
        v0,
        v1,
        v2,
      );
      expect(t, isNotNull);
      expect(t!, closeTo(5.0, 1e-9));
    });

    test('misses when the ray points away from the triangle', () {
      // Same origin, but looking toward +z (the triangle is behind the ray).
      final t = rayTriangleIntersection(
        Vector3(0.25, 0.25, 5),
        Vector3(0, 0, 1),
        v0,
        v1,
        v2,
      );
      expect(t, isNull);
    });

    test('misses when the tapped point is outside the triangle', () {
      // Inside the triangle's plane bounding box corner but outside u+v<=1.
      final t = rayTriangleIntersection(
        Vector3(0.9, 0.9, 5),
        Vector3(0, 0, -1),
        v0,
        v1,
        v2,
      );
      expect(t, isNull);
    });

    test('returns null for a ray parallel to the triangle plane', () {
      final t = rayTriangleIntersection(
        Vector3(0.25, 0.25, 5),
        Vector3(1, 0, 0), // travels in-plane (no z component)
        v0,
        v1,
        v2,
      );
      expect(t, isNull);
    });

    test('is two-sided (hits the back face too)', () {
      // Ray from z = -5 looking toward +z hits the same triangle from behind.
      final t = rayTriangleIntersection(
        Vector3(0.25, 0.25, -5),
        Vector3(0, 0, 1),
        v0,
        v1,
        v2,
      );
      expect(t, isNotNull);
      expect(t!, closeTo(5.0, 1e-9));
    });
  });

  group('nearestPivotHit', () {
    // Two triangles facing the camera at different depths (identity fit, no
    // centering). The near one sits at z = 2, the far one at z = -2.
    final positions = Float32List.fromList(<double>[
      // near triangle (z = 2)
      -1, -1, 2,
      1, -1, 2,
      0, 1, 2,
      // far triangle (z = -2)
      -1, -1, -2,
      1, -1, -2,
      0, 1, -2,
    ]);
    final indices = <int>[0, 1, 2, 3, 4, 5];

    PivotPickRequest req(double ox, double oy, double oz, double dx, double dy,
            double dz) =>
        PivotPickRequest(
          positions: positions,
          indices: indices,
          triangleCount: 2,
          fit: 1.0,
          centerX: 0,
          centerY: 0,
          centerZ: 0,
          ox: ox,
          oy: oy,
          oz: oz,
          dx: dx,
          dy: dy,
          dz: dz,
        );

    test('picks the nearer of two stacked triangles', () {
      // Camera at z = +10 looking toward -z, aimed at the shared center column.
      final hit = nearestPivotHit(req(0, 0, 10, 0, 0, -1));
      expect(hit, isNotNull);
      // Nearer triangle is at z = 2, not the far one at z = -2.
      expect(hit!.z, closeTo(2.0, 1e-6));
      expect(hit.x, closeTo(0.0, 1e-6));
      expect(hit.y, closeTo(0.0, 1e-6));
    });

    test('still picks the nearest when the camera is on the far side', () {
      // Camera at z = -10 looking toward +z: now the z = -2 triangle is nearer.
      final hit = nearestPivotHit(req(0, 0, -10, 0, 0, 1));
      expect(hit, isNotNull);
      expect(hit!.z, closeTo(-2.0, 1e-6));
    });

    test('returns null when the ray misses every triangle', () {
      // Aimed far off to the side, parallel to -z but well outside both tris.
      final hit = nearestPivotHit(req(50, 0, 10, 0, 0, -1));
      expect(hit, isNull);
    });

    test('applies the fit transform (scale about the centered origin)', () {
      // One triangle centered at (10,0,2) in model space; fit 0.5 + center
      // (10,0,0) should place it at world (0,0,1): (p-center)*fit.
      final p = Float32List.fromList(<double>[
        9, -1, 2,
        11, -1, 2,
        10, 1, 2,
      ]);
      final r = PivotPickRequest(
        positions: p,
        indices: const <int>[0, 1, 2],
        triangleCount: 1,
        fit: 0.5,
        centerX: 10,
        centerY: 0,
        centerZ: 0,
        ox: 0,
        oy: 0,
        oz: 10,
        dx: 0,
        dy: 0,
        dz: -1,
      );
      final hit = nearestPivotHit(r);
      expect(hit, isNotNull);
      expect(hit!.z, closeTo(1.0, 1e-6)); // 2 * 0.5
      expect(hit.x, closeTo(0.0, 1e-6)); // (10-10) * 0.5
    });
  });
}
