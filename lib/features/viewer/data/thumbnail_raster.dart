// Pure-Dart, software (CPU) thumbnail rasterizer.
//
// Why this exists: Thermion 0.3.4's GPU capture() crashes the app on device —
// both the live-swapchain path (alpha.4) and a dedicated offscreen
// View+RenderTarget path (alpha.6) destabilized rendering / crashed on the S26
// Ultra. So library thumbnails are produced here instead, from the geometry we
// already parse, with ZERO GPU involvement — it cannot touch (or stall, or
// crash) Filament's render thread.
//
// It draws the mesh into an off-screen RGBA byte buffer with a z-buffered
// barycentric triangle fill and flat, two-sided Lambert shading matching the
// viewer's three directional lights and default iso camera. The output is a
// top-down RGBA8888 buffer; the caller encodes it to PNG on the UI isolate
// (ui.decodeImageFromPixels + toByteData(png)), keeping this file free of any
// dart:ui / engine dependency so it runs in the parse isolate and is
// unit-testable with plain `dart`.
import 'dart:math' as math;
import 'dart:typed_data';

/// Viewer light directions (the direction each light travels), mirroring the
/// three `DirectLight.sun` lights in `scene_view.dart` so the thumbnail shading
/// reads like the live render. Weights are the relative intensities, normalized.
const List<List<double>> _kLightDirs = [
  [0.3, -0.8, 0.5], // key
  [-0.6, -0.2, -0.5], // fill
  [0.1, 0.9, -0.3], // rim
];
const List<double> _kLightWeights = [0.70, 0.40, 0.25];
const double _kAmbient = 0.28;

/// Rasterizes a flat-shaded iso thumbnail of the mesh into an RGBA byte buffer.
///
/// - [positions] : interleaved-free vertex positions, 3 floats per vertex.
/// - [indices]   : triangle indices (length == triangleCount * 3).
/// - [min*]/[max*] : the mesh AABB (used to fit the model into the frame).
/// - [azimuth]/[elevation] : the iso camera angles (radians), matching the
///   viewer's default view so the thumbnail and the opened model agree.
/// - [size] : output is [size] x [size] pixels.
/// - [bgColor] : 0xAARRGGBB background fill.
/// - [surfaceColor] : 0xRRGGBB model base color the light shades.
///
/// Returns a `size*size*4` RGBA buffer (row 0 = top), or `null` if the mesh has
/// no drawable triangles / a degenerate bounding box.
Uint8List? rasterizeThumbnail({
  required Float32List positions,
  required List<int> indices,
  required int triangleCount,
  required double centerX,
  required double centerY,
  required double centerZ,
  required double minX,
  required double minY,
  required double minZ,
  required double maxX,
  required double maxY,
  required double maxZ,
  required double azimuth,
  required double elevation,
  required int size,
  required int bgColor,
  required int surfaceColor,
}) {
  if (size <= 0 || triangleCount <= 0 || indices.length < 3) return null;

  // --- Camera basis (orthographic iso). `dir` points from the model toward the
  // camera; `forward` is the view direction (camera → model). ---
  final ce = math.cos(elevation);
  final dir = _norm(ce * math.sin(azimuth), math.sin(elevation), ce * math.cos(azimuth));
  final fwd = [-dir[0], -dir[1], -dir[2]];
  // right = normalize(cross(forward, worldUp)); camUp = cross(right, forward).
  var right = _cross(fwd[0], fwd[1], fwd[2], 0, 1, 0);
  if (_len(right[0], right[1], right[2]) < 1e-9) {
    // Looking straight up/down — pick an arbitrary stable right axis.
    right = [1.0, 0.0, 0.0];
  } else {
    right = _norm(right[0], right[1], right[2]);
  }
  final up = _cross(right[0], right[1], right[2], fwd[0], fwd[1], fwd[2]);

  // --- Fit: project the 8 AABB corners into eye space to get exact extents. ---
  double exMin = double.infinity, exMax = -double.infinity;
  double eyMin = double.infinity, eyMax = -double.infinity;
  for (var i = 0; i < 8; i++) {
    final px = ((i & 1) == 0 ? minX : maxX) - centerX;
    final py = ((i & 2) == 0 ? minY : maxY) - centerY;
    final pz = ((i & 4) == 0 ? minZ : maxZ) - centerZ;
    final xe = px * right[0] + py * right[1] + pz * right[2];
    final ye = px * up[0] + py * up[1] + pz * up[2];
    if (xe < exMin) exMin = xe;
    if (xe > exMax) exMax = xe;
    if (ye < eyMin) eyMin = ye;
    if (ye > eyMax) eyMax = ye;
  }
  final spanX = exMax - exMin;
  final spanY = eyMax - eyMin;
  final span = math.max(spanX, spanY);
  if (!span.isFinite || span <= 0) return null;

  const pad = 0.10; // fraction of the frame left as a margin
  final scale = (size * (1 - 2 * pad)) / span;
  // Center the projected model in the image.
  final cx = exMin + spanX / 2;
  final cy = eyMin + spanY / 2;
  final ox = size / 2 - cx * scale;
  final oy = size / 2 + cy * scale; // +cy because screen y grows downward

  // --- Buffers. ---
  final out = Uint8List(size * size * 4);
  final bgA = (bgColor >> 24) & 0xff;
  final bgR = (bgColor >> 16) & 0xff;
  final bgG = (bgColor >> 8) & 0xff;
  final bgB = bgColor & 0xff;
  for (var i = 0; i < out.length; i += 4) {
    out[i] = bgR;
    out[i + 1] = bgG;
    out[i + 2] = bgB;
    out[i + 3] = bgA;
  }
  final zbuf = Float32List(size * size)..fillRange(0, size * size, double.infinity);

  final surfR = (surfaceColor >> 16) & 0xff;
  final surfG = (surfaceColor >> 8) & 0xff;
  final surfB = surfaceColor & 0xff;

  // Reused scratch for the three projected vertices: sx, sy, depth.
  final tris = math.min(triangleCount, indices.length ~/ 3);
  for (var t = 0; t < tris; t++) {
    final i0 = indices[t * 3], i1 = indices[t * 3 + 1], i2 = indices[t * 3 + 2];
    final a0 = i0 * 3, a1 = i1 * 3, a2 = i2 * 3;

    final p0x = positions[a0] - centerX,
        p0y = positions[a0 + 1] - centerY,
        p0z = positions[a0 + 2] - centerZ;
    final p1x = positions[a1] - centerX,
        p1y = positions[a1 + 1] - centerY,
        p1z = positions[a1 + 2] - centerZ;
    final p2x = positions[a2] - centerX,
        p2y = positions[a2 + 1] - centerY,
        p2z = positions[a2 + 2] - centerZ;

    // Geometric (flat) face normal for two-sided Lambert shading.
    final ux = p1x - p0x, uy = p1y - p0y, uz = p1z - p0z;
    final vx = p2x - p0x, vy = p2y - p0y, vz = p2z - p0z;
    final nx = uy * vz - uz * vy;
    final ny = uz * vx - ux * vz;
    final nz = ux * vy - uy * vx;
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-12) continue; // degenerate triangle
    final inx = nx / nl, iny = ny / nl, inz = nz / nl;

    // Two-sided Lambert (faces drawn with no culling, winding inconsistent).
    var lum = _kAmbient;
    for (var l = 0; l < 3; l++) {
      final ld = _kLightDirs[l];
      // L = -lightDir (toward the light); two-sided ⇒ use |dot|.
      var d = -(inx * ld[0] + iny * ld[1] + inz * ld[2]);
      if (d < 0) d = -d;
      lum += _kLightWeights[l] * d;
    }
    if (lum > 1.0) lum = 1.0;
    final cr = (surfR * lum).round();
    final cg = (surfG * lum).round();
    final cb = (surfB * lum).round();

    // Eye-space projection → screen pixels + per-vertex depth.
    final s0x = ox + (p0x * right[0] + p0y * right[1] + p0z * right[2]) * scale;
    final s0y = oy - (p0x * up[0] + p0y * up[1] + p0z * up[2]) * scale;
    final d0 = p0x * fwd[0] + p0y * fwd[1] + p0z * fwd[2];
    final s1x = ox + (p1x * right[0] + p1y * right[1] + p1z * right[2]) * scale;
    final s1y = oy - (p1x * up[0] + p1y * up[1] + p1z * up[2]) * scale;
    final d1 = p1x * fwd[0] + p1y * fwd[1] + p1z * fwd[2];
    final s2x = ox + (p2x * right[0] + p2y * right[1] + p2z * right[2]) * scale;
    final s2y = oy - (p2x * up[0] + p2y * up[1] + p2z * up[2]) * scale;
    final d2 = p2x * fwd[0] + p2y * fwd[1] + p2z * fwd[2];

    // Screen-space edge area; |area| ~ 0 ⇒ edge-on, skip.
    final area = (s1x - s0x) * (s2y - s0y) - (s2x - s0x) * (s1y - s0y);
    if (area.abs() < 1e-7) continue;
    final invArea = 1.0 / area;

    // Triangle bounding box, clamped to the image.
    var bxMin = _floor(math.min(s0x, math.min(s1x, s2x)));
    var bxMax = _ceil(math.max(s0x, math.max(s1x, s2x)));
    var byMin = _floor(math.min(s0y, math.min(s1y, s2y)));
    var byMax = _ceil(math.max(s0y, math.max(s1y, s2y)));
    if (bxMin < 0) bxMin = 0;
    if (byMin < 0) byMin = 0;
    if (bxMax > size - 1) bxMax = size - 1;
    if (byMax > size - 1) byMax = size - 1;
    if (bxMin > bxMax || byMin > byMax) continue;

    for (var y = byMin; y <= byMax; y++) {
      final py = y + 0.5;
      for (var x = bxMin; x <= bxMax; x++) {
        final px = x + 0.5;
        // Barycentric weights via signed sub-triangle areas.
        final w0 = ((s1x - px) * (s2y - py) - (s2x - px) * (s1y - py)) * invArea;
        final w1 = ((s2x - px) * (s0y - py) - (s0x - px) * (s2y - py)) * invArea;
        final w2 = ((s0x - px) * (s1y - py) - (s1x - px) * (s0y - py)) * invArea;
        if (w0 < 0 || w1 < 0 || w2 < 0) continue; // outside (CCW or CW via sign)
        final depth = w0 * d0 + w1 * d1 + w2 * d2;
        final zi = y * size + x;
        if (depth >= zbuf[zi]) continue; // farther than what's already drawn
        zbuf[zi] = depth;
        final oi = zi * 4;
        out[oi] = cr;
        out[oi + 1] = cg;
        out[oi + 2] = cb;
        out[oi + 3] = 0xff;
      }
    }
  }
  return out;
}

// --- tiny vector helpers (avoid a vector_math dep so this stays isolate-pure) ---

List<double> _norm(double x, double y, double z) {
  final l = math.sqrt(x * x + y * y + z * z);
  if (l < 1e-12) return [0.0, 0.0, 1.0];
  return [x / l, y / l, z / l];
}

List<double> _cross(
    double ax, double ay, double az, double bx, double by, double bz) {
  return [ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx];
}

double _len(double x, double y, double z) => math.sqrt(x * x + y * y + z * z);

int _floor(double v) => v.floor();
int _ceil(double v) => v.ceil();
