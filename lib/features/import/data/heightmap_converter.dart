import 'dart:math' as math;
import 'dart:typed_data';

/// Converts a 2D image into a 3D heightmap relief and serializes it as a binary
/// STL — a fully on-device "Image → 3D" path (roadmap tier A: heightmap/relief,
/// good for logos, coins, signatures). Pure Dart (only dart:math + typed_data)
/// so it runs in a compute isolate and is unit-testable with plain `dart`.
///
/// Per-pixel luminance drives the height. The output is a *watertight solid*
/// (top relief + flat base + side walls), so it reads as a holdable object — a
/// plaque/coin — rather than a paper-thin sheet, and feeds the existing STL
/// pipeline (parser → viewer → thumbnail) with no renderer changes.

/// Tunables for the relief.
class HeightmapParams {
  const HeightmapParams({
    this.gridMax = 160,
    this.planeSize = 100.0,
    this.relief = 16.0,
    this.base = 6.0,
    this.invert = false,
    this.smoothPasses = 2,
  });

  /// Max grid nodes along the longer image axis (caps triangle count).
  final int gridMax;

  /// World length of the longer in-plane edge (the viewer auto-frames anyway).
  final double planeSize;

  /// Maximum relief height above the base.
  final double relief;

  /// Flat base thickness under the relief.
  final double base;

  /// When true, darker pixels are taller (black-on-white line art / logos /
  /// signatures emboss *upward*). False (default) = brighter pixels are taller,
  /// which is more natural for photos — the lit subject rises, shadows recede.
  final bool invert;

  /// Box-blur passes over the height field. Tames per-pixel spikes and JPEG
  /// noise into a smooth relief (a raw photo heightmap is otherwise spiky). 0 =
  /// off (crisp, for clean line art).
  final int smoothPasses;
}

/// Builds a binary-STL byte buffer from a decoded RGBA image ([rgba] is
/// `imgW*imgH*4` bytes, row-major, top-down). Returns null for an empty image.
Uint8List? heightmapToStl({
  required Uint8List rgba,
  required int imgW,
  required int imgH,
  HeightmapParams params = const HeightmapParams(),
}) {
  if (imgW <= 1 || imgH <= 1 || rgba.length < imgW * imgH * 4) return null;

  // Grid resolution: cap the longer side at gridMax, keep aspect, min 2 nodes.
  final int gw, gh;
  if (imgW >= imgH) {
    gw = math.min(params.gridMax, imgW);
    gh = math.max(2, (gw * imgH / imgW).round());
  } else {
    gh = math.min(params.gridMax, imgH);
    gw = math.max(2, (gh * imgW / imgH).round());
  }

  // In-plane world extents (longer edge = planeSize), centered on the origin.
  final double worldW, worldD;
  if (imgW >= imgH) {
    worldW = params.planeSize;
    worldD = params.planeSize * imgH / imgW;
  } else {
    worldD = params.planeSize;
    worldW = params.planeSize * imgW / imgH;
  }

  // Sample a normalized height (0..1) for each grid node by BLOCK-AVERAGING the
  // image luminance over the node's source cell — anti-aliases away per-pixel
  // noise (vs. a single nearest sample, which made photos spiky). Layout:
  // X = image columns, Z = image rows, Y = up (relief).
  final vGrid = Float32List(gw * gh);
  final halfW = (imgW / gw / 2).ceil();
  final halfH = (imgH / gh / 2).ceil();
  for (var j = 0; j < gh; j++) {
    final cy = (j * (imgH - 1) / (gh - 1)).round();
    final iy0 = math.max(0, cy - halfH), iy1 = math.min(imgH - 1, cy + halfH);
    for (var i = 0; i < gw; i++) {
      final cx = (i * (imgW - 1) / (gw - 1)).round();
      final ix0 = math.max(0, cx - halfW), ix1 = math.min(imgW - 1, cx + halfW);
      var sum = 0.0;
      var count = 0;
      for (var yy = iy0; yy <= iy1; yy++) {
        for (var xx = ix0; xx <= ix1; xx++) {
          final p = (yy * imgW + xx) * 4;
          // Relative luminance (Rec. 709) on the raw sRGB bytes.
          sum += 0.2126 * rgba[p] + 0.7152 * rgba[p + 1] + 0.0722 * rgba[p + 2];
          count++;
        }
      }
      final lum = (sum / count) / 255.0;
      vGrid[j * gw + i] = params.invert ? (1.0 - lum) : lum;
    }
  }
  // Smooth the height field to turn a spiky photo heightmap into a clean relief.
  _boxBlur(vGrid, gw, gh, params.smoothPasses);

  final heights = Float32List(gw * gh);
  for (var k = 0; k < heights.length; k++) {
    heights[k] = params.base + vGrid[k] * params.relief;
  }

  double xAt(int i) => -worldW / 2 + worldW * i / (gw - 1);
  double zAt(int j) => -worldD / 2 + worldD * j / (gh - 1);
  double hAt(int i, int j) => heights[j * gw + i];

  // Triangle count: top + bottom (2 each per cell) + 4 wall strips.
  final cells = (gw - 1) * (gh - 1);
  final wallTris = 2 * ((gw - 1) + (gh - 1)) * 2;
  final triCount = cells * 2 /*top*/ + cells * 2 /*bottom*/ + wallTris;

  final out = ByteData(84 + triCount * 50);
  // 80-byte header left as zeros; triangle count follows.
  out.setUint32(80, triCount, Endian.little);
  var off = 84;

  void tri(double ax, double ay, double az, double bx, double by, double bz,
      double cx, double cy, double cz) {
    // Geometric normal (normalized; zero if degenerate — STL tolerates 0,0,0).
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    var nx = uy * vz - uz * vy;
    var ny = uz * vx - ux * vz;
    var nz = ux * vy - uy * vx;
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl > 1e-12) {
      nx /= nl;
      ny /= nl;
      nz /= nl;
    }
    out.setFloat32(off, nx, Endian.little);
    out.setFloat32(off + 4, ny, Endian.little);
    out.setFloat32(off + 8, nz, Endian.little);
    out.setFloat32(off + 12, ax, Endian.little);
    out.setFloat32(off + 16, ay, Endian.little);
    out.setFloat32(off + 20, az, Endian.little);
    out.setFloat32(off + 24, bx, Endian.little);
    out.setFloat32(off + 28, by, Endian.little);
    out.setFloat32(off + 32, bz, Endian.little);
    out.setFloat32(off + 36, cx, Endian.little);
    out.setFloat32(off + 40, cy, Endian.little);
    out.setFloat32(off + 44, cz, Endian.little);
    // 2-byte attribute count (0) at off+48.
    off += 50;
  }

  // Top relief surface (normals up). CCW seen from +Y.
  for (var j = 0; j < gh - 1; j++) {
    for (var i = 0; i < gw - 1; i++) {
      final x0 = xAt(i), x1 = xAt(i + 1), z0 = zAt(j), z1 = zAt(j + 1);
      final h00 = hAt(i, j), h10 = hAt(i + 1, j);
      final h01 = hAt(i, j + 1), h11 = hAt(i + 1, j + 1);
      tri(x0, h00, z0, x0, h01, z1, x1, h11, z1);
      tri(x0, h00, z0, x1, h11, z1, x1, h10, z0);
    }
  }

  // Flat base at y=0 (normals down). CW seen from +Y so it faces -Y.
  for (var j = 0; j < gh - 1; j++) {
    for (var i = 0; i < gw - 1; i++) {
      final x0 = xAt(i), x1 = xAt(i + 1), z0 = zAt(j), z1 = zAt(j + 1);
      tri(x0, 0, z0, x1, 0, z1, x0, 0, z1);
      tri(x0, 0, z0, x1, 0, z0, x1, 0, z1);
    }
  }

  // Side walls connecting the relief edge down to the base.
  for (var i = 0; i < gw - 1; i++) {
    // Front edge (z = first row) and back edge (z = last row).
    final x0 = xAt(i), x1 = xAt(i + 1);
    final zf = zAt(0), zb = zAt(gh - 1);
    final hf0 = hAt(i, 0), hf1 = hAt(i + 1, 0);
    tri(x0, hf0, zf, x1, 0, zf, x0, 0, zf);
    tri(x0, hf0, zf, x1, hf1, zf, x1, 0, zf);
    final hb0 = hAt(i, gh - 1), hb1 = hAt(i + 1, gh - 1);
    tri(x0, hb0, zb, x0, 0, zb, x1, 0, zb);
    tri(x0, hb0, zb, x1, 0, zb, x1, hb1, zb);
  }
  for (var j = 0; j < gh - 1; j++) {
    // Left edge (x = first col) and right edge (x = last col).
    final z0 = zAt(j), z1 = zAt(j + 1);
    final xl = xAt(0), xr = xAt(gw - 1);
    final hl0 = hAt(0, j), hl1 = hAt(0, j + 1);
    tri(xl, hl0, z0, xl, 0, z0, xl, 0, z1);
    tri(xl, hl0, z0, xl, 0, z1, xl, hl1, z1);
    final hr0 = hAt(gw - 1, j), hr1 = hAt(gw - 1, j + 1);
    tri(xr, hr0, z0, xr, 0, z1, xr, 0, z0);
    tri(xr, hr0, z0, xr, hr1, z1, xr, 0, z1);
  }

  return out.buffer.asUint8List();
}

/// In-place 3×3 box blur over a [w]×[h] grid, [passes] times (edges clamp).
void _boxBlur(Float32List g, int w, int h, int passes) {
  if (passes <= 0 || w < 3 || h < 3) return;
  final tmp = Float32List(g.length);
  for (var p = 0; p < passes; p++) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var sum = 0.0;
        var count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            sum += g[yy * w + xx];
            count++;
          }
        }
        tmp[y * w + x] = sum / count;
      }
    }
    g.setAll(0, tmp);
  }
}
