import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/thumbnail_raster.dart';
import 'package:holdable/features/viewer/data/thumbnail_service.dart';

/// PO feedback #1: library thumbnails must share ONE uniform framing — the
/// object FRONT, tilted up a touch (was a steep 3/4 iso) — and old renders must
/// regenerate so the library is consistent. These lock the framing config and
/// prove it draws a valid, well-framed model through the real CPU rasterizer.
({int r, int g, int b}) _rgb(Uint8List buf, int size, int x, int y) {
  final i = (y * size + x) * 4;
  return (r: buf[i], g: buf[i + 1], b: buf[i + 2]);
}

void main() {
  test('framing constants encode a head-on, tilted-up view (not the old iso)',
      () {
    // azimuth 0 ⇒ the model faces the camera head-on (the old iso was π/4).
    expect(kThumbnailAzimuth, 0.0);
    // A modest upward tilt so the top reads — and strictly flatter than the
    // old 0.6 iso elevation.
    expect(kThumbnailElevation, greaterThan(0.0));
    expect(kThumbnailElevation, lessThan(0.6));
  });

  test('version suffix moved off .t4 so existing thumbnails regenerate', () {
    // The framing changed; the cache key (path suffix) must have moved so the
    // staleness check forces a one-time regen of the whole library.
    expect(kThumbnailVersionSuffix, endsWith('.png'));
    expect(kThumbnailVersionSuffix, isNot('.t4.png'));
    expect(isThumbnailStale('/x/model.t4.png'), isTrue,
        reason: 'an old-version thumbnail is stale under the new suffix');
    expect(isThumbnailStale('/x/model$kThumbnailVersionSuffix'), isFalse);
  });

  test('rendering a cube at the framing constants is lit and well-framed '
      '(not edge-on or a tiny sliver)', () {
    const size = 64;
    final cubePos = Float32List.fromList(<double>[
      -1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, //
      -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1,
    ]);
    final cubeIdx = <int>[
      0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6, 0, 4, 5, 0, 5, 1, //
      3, 2, 6, 3, 6, 7, 0, 3, 7, 0, 7, 4, 1, 5, 6, 1, 6, 2,
    ];
    final buf = rasterizeThumbnail(
      positions: cubePos,
      indices: cubeIdx,
      triangleCount: cubeIdx.length ~/ 3,
      centerX: 0, centerY: 0, centerZ: 0,
      minX: -1, minY: -1, minZ: -1,
      maxX: 1, maxY: 1, maxZ: 1,
      azimuth: kThumbnailAzimuth,
      elevation: kThumbnailElevation,
      size: size,
      bgColor: 0xFF101014,
      surfaceColor: 0x00D1D1DB,
    )!;
    // Center sits on the front face — a lit surface, well above the dark pool
    // (half-Lambert + ambient floors the surface tone far over the ~50 charcoal).
    final c = _rgb(buf, size, size ~/ 2, size ~/ 2);
    expect(c.r, greaterThan(60), reason: 'front face lit head-on');
    expect(c.g, greaterThan(60));
    expect(c.b, greaterThan(60));
    // The head-on model (fit to the frame) fills a healthy share of it — an
    // edge-on/degenerate framing would collapse to a thin sliver.
    var model = 0;
    for (var i = 0; i < buf.length; i += 4) {
      if (buf[i] > 60 && buf[i + 1] > 60 && buf[i + 2] > 60) model++;
    }
    expect(model / (size * size), greaterThan(0.18),
        reason: 'front-on model fills the frame, not a sliver');
  });
}
