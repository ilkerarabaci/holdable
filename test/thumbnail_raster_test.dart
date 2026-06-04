import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/thumbnail_raster.dart';

/// Returns true if pixel (x,y) in an RGBA8888 [size]×[size] buffer equals
/// the given opaque-ish RGB (alpha ignored).
bool _isRgb(Uint8List buf, int size, int x, int y, int r, int g, int b) {
  final i = (y * size + x) * 4;
  return buf[i] == r && buf[i + 1] == g && buf[i + 2] == b;
}

void main() {
  const size = 64;
  const bg = 0xFF101014; // opaque dark
  const surface = 0x00D1D1DB; // light neutral (alpha ignored by rasterizer)
  const az = math.pi / 4, el = 0.6;

  // A unit cube centered at the origin: 8 verts, 12 triangles, indexed.
  // Front-facing winding doesn't matter (two-sided shading).
  final cubePos = Float32List.fromList(<double>[
    -1, -1, -1, // 0
    1, -1, -1, // 1
    1, 1, -1, // 2
    -1, 1, -1, // 3
    -1, -1, 1, // 4
    1, -1, 1, // 5
    1, 1, 1, // 6
    -1, 1, 1, // 7
  ]);
  final cubeIdx = <int>[
    0, 1, 2, 0, 2, 3, // back
    4, 6, 5, 4, 7, 6, // front
    0, 4, 5, 0, 5, 1, // bottom
    3, 2, 6, 3, 6, 7, // top
    0, 3, 7, 0, 7, 4, // left
    1, 5, 6, 1, 6, 2, // right
  ];

  Uint8List rasterCube() => rasterizeThumbnail(
        positions: cubePos,
        indices: cubeIdx,
        triangleCount: cubeIdx.length ~/ 3,
        centerX: 0, centerY: 0, centerZ: 0,
        minX: -1, minY: -1, minZ: -1,
        maxX: 1, maxY: 1, maxZ: 1,
        azimuth: az, elevation: el,
        size: size,
        bgColor: bg,
        surfaceColor: surface,
      )!;

  test('produces a full-size RGBA buffer', () {
    final buf = rasterCube();
    expect(buf.length, size * size * 4);
  });

  test('background corners stay the background color', () {
    final buf = rasterCube();
    // The 10% margin guarantees the extreme corners are never covered.
    expect(_isRgb(buf, size, 0, 0, 0x10, 0x10, 0x14), isTrue);
    expect(_isRgb(buf, size, size - 1, size - 1, 0x10, 0x10, 0x14), isTrue);
    // All background pixels are fully opaque.
    expect(buf[3], 0xFF);
  });

  test('the model is actually drawn (center differs from background)', () {
    final buf = rasterCube();
    var drawn = 0;
    for (var i = 0; i < buf.length; i += 4) {
      if (!(buf[i] == 0x10 && buf[i + 1] == 0x10 && buf[i + 2] == 0x14)) {
        drawn++;
      }
    }
    // A centered cube at this iso angle covers a large fraction of the frame.
    expect(drawn, greaterThan(size * size ~/ 4));
    // The center pixel is on the model.
    expect(
      _isRgb(buf, size, size ~/ 2, size ~/ 2, 0x10, 0x10, 0x14),
      isFalse,
    );
  });

  test('shading varies across faces (not a flat silhouette)', () {
    final buf = rasterCube();
    final tones = <int>{};
    for (var i = 0; i < buf.length; i += 4) {
      final r = buf[i], g = buf[i + 1], b = buf[i + 2];
      if (r == 0x10 && g == 0x10 && b == 0x14) continue; // skip background
      tones.add((r << 16) | (g << 8) | b);
    }
    // Different cube faces have different normals → different Lambert tones.
    expect(tones.length, greaterThan(1));
  });

  test('returns null for an empty mesh', () {
    final buf = rasterizeThumbnail(
      positions: Float32List(0),
      indices: const <int>[],
      triangleCount: 0,
      centerX: 0, centerY: 0, centerZ: 0,
      minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 0, maxZ: 0,
      azimuth: az, elevation: el,
      size: size,
      bgColor: bg,
      surfaceColor: surface,
    );
    expect(buf, isNull);
  });
}
