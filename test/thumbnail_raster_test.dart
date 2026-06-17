import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/thumbnail_raster.dart';

/// RGB of pixel (x,y) in an RGBA8888 [size]×[size] buffer (alpha ignored).
({int r, int g, int b}) _rgb(Uint8List buf, int size, int x, int y) {
  final i = (y * size + x) * 4;
  return (r: buf[i], g: buf[i + 1], b: buf[i + 2]);
}

void main() {
  const size = 64;
  const bg = 0xFF101014; // opaque dark (R=16, G=16, B=20)
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

  test('produces a full-size RGBA buffer (downsampled back to size)', () {
    final buf = rasterCube();
    expect(buf.length, size * size * 4);
  });

  test('background is a radial charcoal pool — brighter toward the focal corner',
      () {
    final buf = rasterCube();
    // The 10% margin guarantees the extreme corners are background, not model.
    final tl = _rgb(buf, size, 0, 0); // upper-left, nearest the pool focal
    final br = _rgb(buf, size, size - 1, size - 1); // far corner, deepest
    // The "Studio Void" radial pool (focal ~40%/30%) brightens toward the
    // upper-left and deepens to near-black at the far corner.
    expect(tl.r, greaterThan(br.r), reason: 'pool brightens toward the focal');
    expect(tl.g, greaterThan(br.g));
    expect(tl.b, greaterThan(br.b));
    // Dark charcoal, fully opaque.
    expect(buf[3], 0xFF);
    expect(tl.r, lessThan(60), reason: 'charcoal pedestal, not a bright bg');
    expect(br.r, lessThan(40), reason: 'deepens to near-black at the corner');
  });

  test('the model is actually drawn (center is a lit surface, not background)',
      () {
    final buf = rasterCube();
    // The center pixel is on the model; the surface (light neutral, shaded)
    // is much brighter than the dark background gradient (max ~17).
    final center = _rgb(buf, size, size ~/ 2, size ~/ 2);
    expect(center.r, greaterThan(60), reason: 'lit surface, not dark bg');
    expect(center.g, greaterThan(60));
    expect(center.b, greaterThan(60));
  });

  test('shading varies across faces (not a flat silhouette)', () {
    final buf = rasterCube();
    // Sample bright (lit-surface) pixels only — anything well above the dark
    // background gradient — and collect their tones.
    final tones = <int>{};
    for (var i = 0; i < buf.length; i += 4) {
      final r = buf[i], g = buf[i + 1], b = buf[i + 2];
      if (r < 40 && g < 40 && b < 40) continue; // skip background gradient
      tones.add((r << 16) | (g << 8) | b);
    }
    // Different cube faces have different normals → different shaded tones.
    expect(tones.length, greaterThan(1));
  });

  test('chromatic Prism rim — blue fringe left of the model, red fringe right',
      () {
    final buf = rasterCube();
    // The "D" signature: a red chromatic fringe just off the silhouette's right
    // edge and a blue fringe off the left. Scan for a clearly blue-biased pixel
    // in the left half and a red-biased one in the right half (the neutral pool
    // is ~achromatic, the lit model is ~grey, so only the rim trips these).
    var bluishLeft = false, reddishRight = false;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = _rgb(buf, size, x, y);
        if (x < size ~/ 2 && p.b > p.r + 12 && p.b > 28) bluishLeft = true;
        if (x >= size ~/ 2 && p.r > p.b + 12 && p.r > 28) reddishRight = true;
      }
    }
    expect(bluishLeft, isTrue,
        reason: 'blue chromatic rim on the left silhouette edge');
    expect(reddishRight, isTrue,
        reason: 'red chromatic rim on the right silhouette edge');
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
