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
// barycentric triangle fill and flat (per-face) shading: half-Lambert key/fill/
// rim diffuse, a cheap Blinn-Phong specular highlight, and a faint Fresnel rim,
// over a vertical background gradient. Rendering happens at 2× (SSAA) and is
// box-downsampled to the requested size for clean edges. The output is a
// top-down RGBA8888 buffer; the caller encodes it to PNG on the UI isolate
// (ui.decodeImageFromPixels + toByteData(png)), keeping this file free of any
// dart:ui / engine dependency so it runs in the parse isolate and is
// unit-testable with plain `dart`.
import 'dart:math' as math;
import 'dart:typed_data';

/// Viewer light directions (the direction each light travels), mirroring the
/// three `DirectLight.sun` lights in `scene_view.dart` so the thumbnail shading
/// reads like the live render. Weights are the relative intensities.
const List<List<double>> _kLightDirs = [
  [0.3, -0.8, 0.5], // key
  [-0.6, -0.2, -0.5], // fill
  [0.1, 0.9, -0.3], // rim
];
const List<double> _kLightWeights = [0.70, 0.40, 0.25];
const double _kAmbient = 0.26;

/// Blinn-Phong specular: tightness (exponent) and white-highlight strength.
const double _kShininess = 24.0;
const double _kSpecular = 0.28;

/// Fresnel rim term (a faint light edge where the surface turns away from the
/// camera) — exponent + strength. Keeps silhouettes from going flat/muddy.
const double _kRimPower = 2.5;
const double _kRim = 0.18;

/// Supersampling factor. The scene is rasterized at [size]·[_kSsaa] and box-
/// downsampled, so edges are anti-aliased without any per-pixel coverage math.
const int _kSsaa = 2;

/// Vertical background gradient: the top is this fraction lighter and the
/// bottom this fraction darker than [bgColor] (model pixels overwrite it).
const double _kBgGradient = 0.08;

/// Rasterizes a flat-shaded iso thumbnail of the mesh into an RGBA byte buffer.
///
/// - [positions] : interleaved-free vertex positions, 3 floats per vertex.
/// - [indices]   : triangle indices (length == triangleCount * 3).
/// - [min*]/[max*] : the mesh AABB (used to fit the model into the frame).
/// - [azimuth]/[elevation] : the iso camera angles (radians), matching the
///   viewer's default view so the thumbnail and the opened model agree.
/// - [size] : output is [size] x [size] pixels.
/// - [bgColor] : 0xAARRGGBB background fill (top/bottom shaded into a gradient).
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

  // Render at 2× then box-downsample to [size] for cheap anti-aliasing.
  final ss = size * _kSsaa;

  // --- Camera basis (orthographic iso). `dir` points from the model toward the
  // camera; `fwd` is the view direction (camera → model). For an orthographic
  // camera the view vector V (surface → camera) is constant and equals `dir`. ---
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
  final scale = (ss * (1 - 2 * pad)) / span;
  // Center the projected model in the (supersampled) image.
  final cx = exMin + spanX / 2;
  final cy = eyMin + spanY / 2;
  final ox = ss / 2 - cx * scale;
  final oy = ss / 2 + cy * scale; // +cy because screen y grows downward

  // --- Supersampled buffers: vertical background gradient first. ---
  final ssBuf = Uint8List(ss * ss * 4);
  final bgA = (bgColor >> 24) & 0xff;
  final bgR = (bgColor >> 16) & 0xff;
  final bgG = (bgColor >> 8) & 0xff;
  final bgB = bgColor & 0xff;
  for (var y = 0; y < ss; y++) {
    // f: +_kBgGradient at the top row → -_kBgGradient at the bottom row.
    final f = ss > 1
        ? _kBgGradient * (1.0 - 2.0 * (y / (ss - 1)))
        : 0.0;
    final r = _clamp8((bgR * (1.0 + f)).round());
    final g = _clamp8((bgG * (1.0 + f)).round());
    final b = _clamp8((bgB * (1.0 + f)).round());
    var oi = y * ss * 4;
    for (var x = 0; x < ss; x++) {
      ssBuf[oi] = r;
      ssBuf[oi + 1] = g;
      ssBuf[oi + 2] = b;
      ssBuf[oi + 3] = bgA;
      oi += 4;
    }
  }
  final zbuf = Float32List(ss * ss)..fillRange(0, ss * ss, double.infinity);

  // Surface base color, linearized so shading happens in (approx) linear light
  // and is re-encoded to sRGB on write (the "mild sRGB gamma" — keeps midtones
  // from washing out the way shading raw sRGB does).
  final surfR = _srgbToLinear(((surfaceColor >> 16) & 0xff) / 255.0);
  final surfG = _srgbToLinear(((surfaceColor >> 8) & 0xff) / 255.0);
  final surfB = _srgbToLinear((surfaceColor & 0xff) / 255.0);

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

    // Geometric (flat) face normal for two-sided shading.
    final ux = p1x - p0x, uy = p1y - p0y, uz = p1z - p0z;
    final vx = p2x - p0x, vy = p2y - p0y, vz = p2z - p0z;
    var nx = uy * vz - uz * vy;
    var ny = uz * vx - ux * vz;
    var nz = ux * vy - uy * vx;
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-12) continue; // degenerate triangle
    nx /= nl;
    ny /= nl;
    nz /= nl;
    // Two-sided: flip the normal to face the camera (V = dir for ortho) so
    // back faces (OBJ/STL winding is inconsistent) light the same as front.
    if (nx * dir[0] + ny * dir[1] + nz * dir[2] < 0) {
      nx = -nx;
      ny = -ny;
      nz = -nz;
    }
    final ndotv = nx * dir[0] + ny * dir[1] + nz * dir[2]; // ∈ [0,1] now

    // Diffuse (half-Lambert) + Blinn-Phong specular over the three lights.
    var diffuse = _kAmbient;
    var spec = 0.0;
    for (var l = 0; l < 3; l++) {
      final ld = _kLightDirs[l];
      // L = direction toward the light = -lightTravelDir.
      final lx = -ld[0], ly = -ld[1], lz = -ld[2];
      final ll = math.sqrt(lx * lx + ly * ly + lz * lz);
      final ux2 = lx / ll, uy2 = ly / ll, uz2 = lz / ll;
      final ndotl = nx * ux2 + ny * uy2 + nz * uz2;
      // Half-Lambert (Valve): (dot*0.5+0.5)² — soft wrap, no hard terminator.
      final wrap = ndotl * 0.5 + 0.5;
      diffuse += _kLightWeights[l] * wrap * wrap;
      // Specular only from the lit side.
      if (ndotl > 0) {
        // Half-vector between light and view (view = dir, normalized).
        var hx = ux2 + dir[0], hy = uy2 + dir[1], hz = uz2 + dir[2];
        final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
        if (hl > 1e-9) {
          hx /= hl;
          hy /= hl;
          hz /= hl;
          final ndoth = nx * hx + ny * hy + nz * hz;
          if (ndoth > 0) {
            spec += _kLightWeights[l] *
                _kSpecular *
                math.pow(ndoth, _kShininess).toDouble();
          }
        }
      }
    }
    // Faint Fresnel rim where the face turns away from the camera.
    final rim = _kRim * math.pow(1.0 - ndotv, _kRimPower).toDouble();

    // Linear shaded color: tinted diffuse + rim, plus a white specular/rim cap.
    final addWhite = spec + rim;
    var lr = surfR * diffuse + addWhite;
    var lg = surfG * diffuse + addWhite;
    var lb = surfB * diffuse + addWhite;
    if (lr > 1.0) lr = 1.0;
    if (lg > 1.0) lg = 1.0;
    if (lb > 1.0) lb = 1.0;
    // Encode back to sRGB for the 8-bit buffer (mild gamma).
    final cr = (_linearToSrgb(lr) * 255.0).round();
    final cg = (_linearToSrgb(lg) * 255.0).round();
    final cb = (_linearToSrgb(lb) * 255.0).round();

    // Eye-space projection → (supersampled) screen pixels + per-vertex depth.
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

    // Triangle bounding box, clamped to the supersampled image.
    var bxMin = _floor(math.min(s0x, math.min(s1x, s2x)));
    var bxMax = _ceil(math.max(s0x, math.max(s1x, s2x)));
    var byMin = _floor(math.min(s0y, math.min(s1y, s2y)));
    var byMax = _ceil(math.max(s0y, math.max(s1y, s2y)));
    if (bxMin < 0) bxMin = 0;
    if (byMin < 0) byMin = 0;
    if (bxMax > ss - 1) bxMax = ss - 1;
    if (byMax > ss - 1) byMax = ss - 1;
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
        final zi = y * ss + x;
        if (depth >= zbuf[zi]) continue; // farther than what's already drawn
        zbuf[zi] = depth;
        final oi = zi * 4;
        ssBuf[oi] = cr;
        ssBuf[oi + 1] = cg;
        ssBuf[oi + 2] = cb;
        ssBuf[oi + 3] = 0xff;
      }
    }
  }

  // --- Box-downsample the SS buffer to the requested size. ---
  return _downsample(ssBuf, ss, size, _kSsaa);
}

/// Box-downsamples an [ss]×[ss] RGBA buffer to [size]×[size] by averaging each
/// [factor]×[factor] block (factor == ss / size).
Uint8List _downsample(Uint8List src, int ss, int size, int factor) {
  final out = Uint8List(size * size * 4);
  final n = factor * factor;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var r = 0, g = 0, b = 0, a = 0;
      final sy0 = y * factor, sx0 = x * factor;
      for (var dy = 0; dy < factor; dy++) {
        var si = ((sy0 + dy) * ss + sx0) * 4;
        for (var dx = 0; dx < factor; dx++) {
          r += src[si];
          g += src[si + 1];
          b += src[si + 2];
          a += src[si + 3];
          si += 4;
        }
      }
      final oi = (y * size + x) * 4;
      out[oi] = (r / n).round();
      out[oi + 1] = (g / n).round();
      out[oi + 2] = (b / n).round();
      out[oi + 3] = (a / n).round();
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

/// sRGB component (0..1) → linear.
double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// linear component (0..1) → sRGB.
double _linearToSrgb(double c) {
  if (c <= 0.0) return 0.0;
  if (c >= 1.0) return 1.0;
  return c <= 0.0031308
      ? c * 12.92
      : 1.055 * math.pow(c, 1.0 / 2.4).toDouble() - 0.055;
}

int _clamp8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int _floor(double v) => v.floor();
int _ceil(double v) => v.ceil();
