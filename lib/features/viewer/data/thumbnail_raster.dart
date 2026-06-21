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
// rim diffuse, a cheap Blinn-Phong specular highlight, and a faint Fresnel rim.
// The "Studio Void / Prism" look (design direction D): the model sits on a
// radial charcoal pool with a corner vignette and a soft grounded contact
// shadow, finished with a faint chromatic rim — a red fringe just off the
// silhouette's right edge and a blue fringe off the left (Holdable's spectrum
// identity), all achievable without a GPU blur. Rendering happens at 2× (SSAA)
// and is box-downsampled for clean edges. The output is a top-down RGBA8888
// buffer; the caller encodes it to PNG on the UI isolate, keeping this file free
// of any dart:ui / engine dependency so it runs in the parse isolate and is
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

// --- "Studio Void / Prism" background treatment (design direction D) ---------
// Radial charcoal pool: a soft pedestal of light off-center toward the upper
// left, deepening to near-black at the edges.
const List<double> _kPoolInner = [0x23 / 255, 0x28 / 255, 0x30 / 255]; // #232830
const List<double> _kPoolMid = [0x14 / 255, 0x17 / 255, 0x1D / 255]; // #14171D
const List<double> _kPoolOuter = [0x0A / 255, 0x0C / 255, 0x10 / 255]; // #0A0C10
const double _kPoolFocalX = 0.40, _kPoolFocalY = 0.30; // focal, fraction of frame
const double _kPoolMidStop = 0.46; // radius fraction where the mid stop sits
const double _kVignette = 0.36; // extra corner darkening (0..1)

/// Soft contact shadow grounding the model under its projected base.
const double _kContactStrength = 0.55;

/// Chromatic "Prism" rim: a faint red fringe just off the model's right edge and
/// a blue fringe off the left. Strength by distance (in supersampled px) from
/// the silhouette — a 3-px falloff fakes a soft fringe with no blur kernel.
const List<int> _kRimRed = [255, 90, 120];
const List<int> _kRimBlue = [80, 150, 255];
// Strength by distance (supersampled px) from the silhouette. Widened 3→6 px
// and strengthened (alpha.53): the rim was ~1px after downsample → invisible at
// 256px, so the "D" redesign didn't read. This makes the chromatic edge a clear
// ~3px band in the output without being garish.
const List<double> _kRimFalloff = [0.85, 0.72, 0.58, 0.44, 0.30, 0.16];

/// Half the thumbnail camera's vertical FOV, as a tangent (PO feedback #1's
/// "70mm" look). ~0.13 sits the camera ≈3.8 model-spans back ⇒ a MILD long-lens
/// perspective (near faces grow only ~15% vs far), not a wide-angle bulge.
/// Larger ⇒ closer camera ⇒ stronger perspective.
const double _kThumbHalfFovTan = 0.13;

/// Rasterizes a flat-shaded iso thumbnail of the mesh into an RGBA byte buffer.
///
/// - [positions] : interleaved-free vertex positions, 3 floats per vertex.
/// - [indices]   : triangle indices (length == triangleCount * 3).
/// - [min*]/[max*] : the mesh AABB (used to fit the model into the frame).
/// - [azimuth]/[elevation] : the iso camera angles (radians), matching the
///   viewer's default view so the thumbnail and the opened model agree.
/// - [size] : output is [size] x [size] pixels.
/// - [bgColor] : retained for API compatibility; the D treatment paints a fixed
///   radial charcoal pool, so this is currently unused by the background fill.
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

  // 70mm-equivalent MILD perspective (PO feedback #1): sit the camera `camDist`
  // back along the view axis and perspective-divide by per-vertex depth below, so
  // near faces grow a touch vs far — a gentle long-lens read. `scale` already
  // matches the ortho center, so depth 0 projects identically; the 10% fit pad
  // absorbs the small near-face growth.
  final camDist = (span / 2) / _kThumbHalfFovTan;

  // --- Supersampled buffers: radial charcoal pool + corner vignette first. ---
  final ssBuf = Uint8List(ss * ss * 4);
  final fx = _kPoolFocalX * (ss - 1);
  final fy = _kPoolFocalY * (ss - 1);
  // Normalize the radius so the gradient reaches the outer stop near the far
  // corner (the design's ~125%/115% ellipse).
  final farX = math.max(fx, (ss - 1) - fx);
  final farY = math.max(fy, (ss - 1) - fy);
  final maxR = math.max(1e-6, math.sqrt(farX * farX + farY * farY) / 1.15);
  final ctr = (ss - 1) / 2.0;
  final vMax = math.max(1e-6, math.sqrt(2 * ctr * ctr));
  for (var y = 0; y < ss; y++) {
    var oi = y * ss * 4;
    for (var x = 0; x < ss; x++) {
      final dx = x - fx, dy = y - fy;
      var t = math.sqrt(dx * dx + dy * dy) / maxR;
      if (t > 1.0) t = 1.0;
      double rr, gg, bb;
      if (t < _kPoolMidStop) {
        final u = t / _kPoolMidStop;
        rr = _kPoolInner[0] + (_kPoolMid[0] - _kPoolInner[0]) * u;
        gg = _kPoolInner[1] + (_kPoolMid[1] - _kPoolInner[1]) * u;
        bb = _kPoolInner[2] + (_kPoolMid[2] - _kPoolInner[2]) * u;
      } else {
        final u = (t - _kPoolMidStop) / (1.0 - _kPoolMidStop);
        rr = _kPoolMid[0] + (_kPoolOuter[0] - _kPoolMid[0]) * u;
        gg = _kPoolMid[1] + (_kPoolOuter[1] - _kPoolMid[1]) * u;
        bb = _kPoolMid[2] + (_kPoolOuter[2] - _kPoolMid[2]) * u;
      }
      // Quadratic corner vignette on top.
      final ddx = x - ctr, ddy = y - ctr;
      final vd = math.sqrt(ddx * ddx + ddy * ddy) / vMax;
      final vig = 1.0 - _kVignette * vd * vd;
      ssBuf[oi] = _clamp8((rr * vig * 255.0).round());
      ssBuf[oi + 1] = _clamp8((gg * vig * 255.0).round());
      ssBuf[oi + 2] = _clamp8((bb * vig * 255.0).round());
      ssBuf[oi + 3] = 0xff;
      oi += 4;
    }
  }

  // --- Soft contact shadow at the model's projected base (drawn into the bg;
  // the model overdraws its center, leaving a grounding pool around the base). ---
  _contactShadow(ssBuf, ss, spanX * scale, spanY * scale);

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
    // Perspective-divide for the mild 70mm look: ps = scale·camDist/(camDist+depth).
    // depth 0 ⇒ ps = scale (matches the ortho fit); near (depth<0) grows, far
    // shrinks. camDist ≫ |depth|, so the divisor is always > 0.
    final d0 = p0x * fwd[0] + p0y * fwd[1] + p0z * fwd[2];
    final ps0 = scale * camDist / (camDist + d0);
    final s0x = ox + (p0x * right[0] + p0y * right[1] + p0z * right[2]) * ps0;
    final s0y = oy - (p0x * up[0] + p0y * up[1] + p0z * up[2]) * ps0;
    final d1 = p1x * fwd[0] + p1y * fwd[1] + p1z * fwd[2];
    final ps1 = scale * camDist / (camDist + d1);
    final s1x = ox + (p1x * right[0] + p1y * right[1] + p1z * right[2]) * ps1;
    final s1y = oy - (p1x * up[0] + p1y * up[1] + p1z * up[2]) * ps1;
    final d2 = p2x * fwd[0] + p2y * fwd[1] + p2z * fwd[2];
    final ps2 = scale * camDist / (camDist + d2);
    final s2x = ox + (p2x * right[0] + p2y * right[1] + p2z * right[2]) * ps2;
    final s2y = oy - (p2x * up[0] + p2y * up[1] + p2z * up[2]) * ps2;

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

  // --- Chromatic "Prism" rim: tint bg pixels just off the silhouette — red on
  // the right edge, blue on the left — using the z-buffer as the model mask. ---
  _chromaticRim(ssBuf, zbuf, ss);

  // --- Box-downsample the SS buffer to the requested size. ---
  return _downsample(ssBuf, ss, size, _kSsaa);
}

/// Darkens an elliptical contact pool centered under the model's projected base.
/// [pw]/[ph] are the model's projected width/height in supersampled pixels.
void _contactShadow(Uint8List buf, int ss, double pw, double ph) {
  final ccx = ss / 2.0;
  final ccy = ss / 2.0 + (ph / 2.0) * 0.98; // just below the lowest model point
  final rx = math.max((pw / 2.0) * 0.95, 6.0);
  final ry = math.max(rx * 0.16, 3.0);
  final yA = math.max(0, (ccy - ry).floor());
  final yB = math.min(ss - 1, (ccy + ry).ceil());
  final xA = math.max(0, (ccx - rx).floor());
  final xB = math.min(ss - 1, (ccx + rx).ceil());
  for (var y = yA; y <= yB; y++) {
    final ny = (y - ccy) / ry;
    for (var x = xA; x <= xB; x++) {
      final nx = (x - ccx) / rx;
      final d2 = nx * nx + ny * ny;
      if (d2 >= 1.0) continue;
      final k = _kContactStrength * (1.0 - d2); // soft falloff to the rim
      final oi = (y * ss + x) * 4;
      buf[oi] = (buf[oi] * (1.0 - k)).round();
      buf[oi + 1] = (buf[oi + 1] * (1.0 - k)).round();
      buf[oi + 2] = (buf[oi + 2] * (1.0 - k)).round();
    }
  }
}

/// Paints the chromatic rim fringe onto background pixels adjacent to the model
/// silhouette: red where the model lies just to the left (the right edge), blue
/// where it lies just to the right (the left edge). [z] != ∞ marks model pixels.
void _chromaticRim(Uint8List buf, Float32List z, int ss) {
  for (var y = 0; y < ss; y++) {
    final row = y * ss;
    for (var x = 0; x < ss; x++) {
      if (z[row + x] != double.infinity) continue; // only tint bg pixels
      for (var d = 0; d < _kRimFalloff.length; d++) {
        final mx = x - (d + 1);
        if (mx >= 0 && z[row + mx] != double.infinity) {
          _tint(buf, (row + x) * 4, _kRimRed, _kRimFalloff[d]);
          break;
        }
      }
      for (var d = 0; d < _kRimFalloff.length; d++) {
        final mx = x + (d + 1);
        if (mx < ss && z[row + mx] != double.infinity) {
          _tint(buf, (row + x) * 4, _kRimBlue, _kRimFalloff[d]);
          break;
        }
      }
    }
  }
}

/// Lerps the RGB at [oi] toward [c] by [k] (a soft additive-style tint).
void _tint(Uint8List buf, int oi, List<int> c, double k) {
  buf[oi] = _clamp8((buf[oi] + (c[0] - buf[oi]) * k).round());
  buf[oi + 1] = _clamp8((buf[oi + 1] + (c[1] - buf[oi + 1]) * k).round());
  buf[oi + 2] = _clamp8((buf[oi + 2] + (c[2] - buf[oi + 2]) * k).round());
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
