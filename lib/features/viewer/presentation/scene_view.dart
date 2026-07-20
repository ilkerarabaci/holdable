import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
// Hide Flutter's View/Texture so Thermion's same-named types resolve without a
// name clash (we don't use Flutter's View/Texture widgets in this file).
import 'package:flutter/widgets.dart' hide View, Texture;
import 'package:path_provider/path_provider.dart';
// Thermion re-exports thermion_dart (ThermionFlutterPlugin, ThermionViewer,
// Geometry, FilamentApp, DirectLight, Camera, View, RenderTarget, the
// material/culling/index enums), vector_math_64 (Vector3, Matrix4) and
// dart:typed_data. Hide only Material (collides with flutter/material, unused).
import 'package:thermion_flutter/thermion_flutter.dart' hide Material;
// Constant-irradiance ambient (option A / black-underside fix): builds an
// IndirectLight from spherical harmonics with NO cubemap/reflection texture, so
// the no-IBL environments (None/Café) get a uniform ~0-GPU ambient floor that
// lifts downward facets out of pure black. There is no public viewer API for a
// harmonics-only IBL (loadIbl takes a KTX path), so reach the impl factory
// directly — the dependency is pinned to a git ref, so this stays stable.
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:thermion_dart/src/filament/src/implementation/ffi_indirect_light.dart'
    show FFIIndirectLight;

import '../data/model_parser.dart';
import '../data/thumbnail_raster.dart';
// Single source of truth for the library thumbnail framing. The viewer's in-
// place thumbnail (_load below) MUST use these, not the viewer-camera iso angle —
// otherwise opening a model bakes a different framing than the standalone
// thumbnail service and the library goes inconsistent (the alpha.54 regression).
import '../data/thumbnail_service.dart' show kThumbnailAzimuth, kThumbnailElevation;
import 'environment_backdrop.dart';

/// Status pushed up to the host screen (drives the loading spinner + Info panel).
class ModelSceneStatus {
  const ModelSceneStatus({
    this.loading = true,
    this.error,
    this.verts,
    this.tris,
    this.parseMs,
  });

  final bool loading;
  final String? error;
  final int? verts;
  final int? tris;
  final int? parseMs;
}

/// Imperative handle for the host screen to drive the viewer (render mode,
/// preset camera, model color). Implemented by the active renderer.
class ModelSceneController {
  _ModelSceneViewState? _state;

  void _attach(_ModelSceneViewState s) => _state = s;
  void _detach(_ModelSceneViewState s) {
    if (identical(_state, s)) _state = null;
  }

  void setRenderMode(String mode) => _state?._setRenderMode(mode);
  void setView(String preset) => _state?._setPreset(preset);

  /// Camera lens/projection preset: '70mm' (default), '24mm', 'fisheye' or
  /// 'ortho'. Changes the focal length / projection without moving the orbit.
  void setProjection(String preset) => _state?._setProjection(preset);

  /// Toggles a ground/contact shadow under the model (#4): a shadow-catcher
  /// plane plus one overhead shadow-casting sun. Off by default.
  void setGroundShadow(bool on) => _state?._setGroundShadow(on);

  /// Hand-tracking control (F4): drive the framing from a gesture pose instead
  /// of touch. [yaw] rotates the model (orbit azimuth), [scale] zooms (≥1 =
  /// bigger), [tx]/[ty] pan it in-frame (normalized −1..1). See hand_gesture.dart.
  void setHandPose({
    required double yaw,
    required double scale,
    required double tx,
    required double ty,
  }) =>
      _state?._setHandPose(yaw, scale, tx, ty);

  /// Sets the model's base color (the surface tint the light shades).
  void setColor(Color color) => _state?._setColor(color);

  /// The user's chosen base color as sRGB 0xAARRGGBB, or null when they haven't
  /// picked one (or a texture is showing) so callers fall back to the model's
  /// own color. Lets the AR export bake the viewer's color (Faz D / #10).
  int? get pickedColorArgb => _state?._pickedColorArgb;

  /// Current surface opacity (1.0 solid, 0.35 in x-ray), baked into the AR
  /// export so a see-through model stays see-through in AR (Faz D / #10).
  double get currentOpacity => _state?._currentAlpha ?? 1.0;

  /// Light-rig intensity multiplier (0.2–2.5; 1.0 = default brightness).
  void setLightIntensity(double factor) =>
      _state?._setLightIntensity(factor);

  /// Rotates the whole light rig around Y by [azimuthRad] (relight angle).
  void setLightAngle(double azimuthRad) => _state?._setLightAzimuth(azimuthRad);

  /// Selects the lighting environment (Faz C / PO #6): swings/recolors the
  /// directional rig and loads/removes the bundled IBL to match the picked
  /// procedural backdrop. The backdrop itself is a Flutter layer (see
  /// EnvironmentBackdrop); this only drives the renderer's lighting.
  void setEnvironment(AppEnvironment env) => _state?._setEnvironment(env);

  /// Applies a bundled texture asset (e.g. `assets/textures/wood.jpg`) to the
  /// model's surface, or removes any texture when [assetPath] is null (the
  /// base color drives the surface again).
  void setTextureAsset(String? assetPath) =>
      _state?._setTextureAsset(assetPath);

  /// Shading preference: 'auto' (default), 'smooth' or 'flat' facets.
  void setShading(String shading) => _state?._setShading(shading);
}

/// De-indexed flat-shaded copy of a prepared model (per-face normals).
class _FlatModel {
  _FlatModel(this.positions, this.normals, this.uvs, this.colors, this.indices,
      this.indexType);
  final Float32List positions;
  final Float32List normals;
  final Float32List uvs;
  final Float32List? colors; // 4/vertex linear RGBA, null = no baked colors
  final List<int> indices;
  final IndexType indexType;
}

/// 3D viewer surface — **v0.3, Thermion (Google Filament)**.
///
/// The flutter_scene renderer (v0.2, tag `v0.2.0-alpha-flutterscene`) was frozen
/// after device testing showed an Impeller GPU-memory floor we can't control
/// (ADR-002). This renders the model with Filament, which manages its own GPU
/// memory. The model is parsed off the UI isolate by the renderer-agnostic
/// [ModelParser], de-interleaved into Filament's separate attribute buffers, and
/// uploaded via [ThermionViewer.createGeometry] (no glTF round-trip needed).
///
/// Orbit is driven by our own [GestureDetector] math (azimuth / elevation /
/// radius around the model center) rather than Thermion's built-in fixed-orbit
/// handler — that handler felt stiff and couldn't zoom in. This restores the
/// free, responsive feel of the v0.2 viewer.
///
/// Render modes (solid / wireframe / x-ray) rebuild the asset with the matching
/// geometry + material; color is a live base-color swap. Keeps the same widget
/// contract as the prior renderer lines so the host [ViewerScreen] is unchanged.
class ModelSceneView extends StatefulWidget {
  const ModelSceneView({
    super.key,
    required this.controller,
    required this.filePath,
    required this.format,
    required this.background,
    required this.onStatus,
    this.onThumbnail,
    this.onTextureCrashDetected,
  });

  /// Called once when a previous session died mid-texture-pipeline; the value
  /// is the last step that started (read from the crash-trace file).
  final ValueChanged<String>? onTextureCrashDetected;

  final ModelSceneController controller;
  final String filePath;
  final String format; // 'obj' | 'stl'
  final Color background;
  final ValueChanged<ModelSceneStatus> onStatus;
  final ValueChanged<Uint8List>? onThumbnail;

  @override
  State<ModelSceneView> createState() => _ModelSceneViewState();
}

/// Default model surface color until the user picks one (a light neutral).
const Color _kNeutral = Color(0xFFD1D1DB);

/// Render the 3D viewport at this fraction of the device pixel ratio. Filament's
/// full-resolution HDR render targets (color RGBA16F + depth + bloom mips + FXAA)
/// dominate GPU memory and scale ~quadratically with resolution, so on an ultra-
/// dense phone panel 0.75 (~56% of the pixels) is a real memory cut that's barely
/// perceptible. Input stays in LOGICAL space (the viewer's own GestureDetector),
/// so orbit/zoom/pivot-picking are unaffected by the lower render resolution.
const double _kViewportRenderScale = 0.75;

/// The base 6-sun rig (dir x,y,z, intensity): a key + two fills + three dim
/// counter-lights so every facet catches some light without an IBL. The user's
/// intensity multiplier + azimuth rotation are applied on top (see _setLight*).
const List<(double, double, double, double)> _kLightRig = [
  (0.3, -0.8, 0.5, 70000),
  (-0.6, -0.2, -0.5, 38000),
  (0.1, 0.9, -0.3, 22000),
  (-0.3, 0.8, -0.5, 26000),
  (0.6, 0.2, 0.5, 18000),
  (-0.1, -0.9, 0.3, 14000),
];

/// A zero-texture CONSTANT ambient for the no-IBL presets (None/Café) — the
/// black-underside fix. Lighting there is purely directional, so a facet that
/// faces away from every sun crushes to pure black (worst on low-poly solids:
/// the octahedron's whole underside went black, café/none). A real IBL fixes it
/// but costs ~70 MB of GPU cubemap; instead we hand Filament a UNIFORM irradiance
/// built from spherical harmonics with only the DC (band-0) term set — no
/// reflection/irradiance textures, so it is ~0 MB and lifts EVERY facet evenly
/// (even the darkest face a real, directional IBL still misses). Filament expects
/// the 3-band, 27-float coefficient layout; only the first float3 is non-zero for
/// a constant. [_kAmbientFloorLux] is the (tunable) strength — kept low so it
/// only lifts the blacks without flattening the directional shading.
final Float32List _kAmbientSH = Float32List(27)
  ..[0] = 1.0
  ..[1] = 1.0
  ..[2] = 1.0;
const double _kAmbientFloorLux = 6000.0;

/// The colour to bake into the AR export (Faz D / #10): the user's picked colour
/// (sRGB 0xAARRGGBB) when they've chosen one and no texture is showing, else null
/// so the caller falls back to the model's own colour. Pure → unit-tested.
int? arPickedColorArgb({
  required bool colorPicked,
  required bool hasTexture,
  required int baseColorArgb,
}) =>
    (colorPicked && !hasTexture) ? baseColorArgb : null;

/// A pure light-rig preset for an [AppEnvironment] (Faz C / PO #6). It nudges
/// the directional rig to *match* the procedural backdrop the user picked, and
/// is COMPOSED on top of the user's own intensity/azimuth sliders (it never
/// clobbers them — see `_setLightIntensity` / `_setLightAzimuth`):
/// - [intensityScale] multiplies every sun's intensity (on top of the user's),
/// - [azimuthBias] (radians) is added to the rig azimuth (swings the key),
/// - [iblAmount] (0..1) is the bundled studio IBL strength (0 = no IBL),
/// - [colorTemperature] (Kelvin, null = neutral) optionally warms/cools the rig.
class EnvLightPreset {
  const EnvLightPreset({
    required this.intensityScale,
    required this.azimuthBias,
    required this.iblAmount,
    this.colorTemperature,
  });
  final double intensityScale;
  final double azimuthBias;
  final double iblAmount;
  final double? colorTemperature;
}

/// Maps an [AppEnvironment] to its [EnvLightPreset]. Pure (no GPU/viewer) so the
/// env → light-preset contract is unit-testable. `none` is the neutral identity
/// (the directional rig + filmic baseline, unchanged from before Faz C).
EnvLightPreset environmentLightPreset(AppEnvironment env) {
  switch (env) {
    case AppEnvironment.none:
      return const EnvLightPreset(
          intensityScale: 1.0, azimuthBias: 0.0, iblAmount: 0.0);
    case AppEnvironment.cafe:
      // Warm side key swung toward frame-right (~3500K) — the café board's
      // window-light look. No IBL (the bokeh backdrop carries the ambience).
      return const EnvLightPreset(
        intensityScale: 1.0,
        azimuthBias: 0.6,
        iblAmount: 0.0,
        colorTemperature: 3500,
      );
    case AppEnvironment.sky:
      // Bright top key + soft ambient from a gentle IBL (neutral daylight).
      return const EnvLightPreset(
        intensityScale: 1.15,
        azimuthBias: 0.0,
        iblAmount: 0.30,
        colorTemperature: 6500,
      );
    case AppEnvironment.studio:
      // Dual-softbox neutral: the brightest rig + the strongest IBL.
      return const EnvLightPreset(
        intensityScale: 1.25,
        azimuthBias: 0.0,
        iblAmount: 0.50,
        colorTemperature: 6500,
      );
  }
}

/// Direction the ground-shadow sun should point so the cast shadow stays
/// CONSISTENT with the lighting (#4, Efe feedback #3): the shadow must fall
/// AWAY from the dominant key light, so the sun points along the key's own
/// direction. We take the rig's key sun ([_kLightRig]`[0]`) and rotate it about
/// Y by the SAME composed azimuth the rig uses (`userAzimuth + envBias`) via the
/// same Y-rotation as [_ModelSceneViewState._rotatedDir]. Returns a normalized
/// (x,y,z). Pure — no GPU/viewer — so the contract is unit-testable.
({double x, double y, double z}) groundShadowSunDirection({
  required double keyX,
  required double keyY,
  required double keyZ,
  required double azimuth,
}) {
  final ca = math.cos(azimuth), sa = math.sin(azimuth);
  var x = keyX * ca + keyZ * sa;
  final y = keyY;
  var z = -keyX * sa + keyZ * ca;
  final len = math.sqrt(x * x + y * y + z * z);
  if (len > 1e-12) {
    x /= len;
    z /= len;
    return (x: x, y: y / len, z: z);
  }
  return (x: 0.0, y: -1.0, z: 0.0);
}

/// The ground-shadow sun's intensity for a user [lightIntensity] multiplier and
/// the active environment [intensityScale] (#4): the cast shadow should respond
/// to how bright the rig is. Clamped so a very dim/very bright rig still yields
/// a readable contact shadow. Pure — unit-testable.
double groundShadowSunIntensity({
  required double lightIntensity,
  required double envIntensityScale,
}) =>
    (60000 * lightIntensity * envIntensityScale).clamp(20000.0, 120000.0);

/// Resolved camera projection parameters for a lens preset (#9). One of these
/// is non-null per preset, telling [_ModelSceneViewState._applyProjection]
/// which Filament projection call to make:
/// - [focalLength] (mm) → `Camera.setLensProjection` (the two perspective
///   presets, 70mm tele-ish and 24mm wide),
/// - [fovDegrees] (vertical FoV) → `setProjectionFromVerticalFieldOfView`
///   (the ultra-wide "fisheye" look — NOT a true fisheye, just a very wide FoV),
/// - [ortho] true → an orthographic projection sized from the fit radius.
///
/// Pure data (no GPU/aspect) so the preset→params mapping is unit-testable.
class LensParams {
  const LensParams({this.focalLength, this.fovDegrees, this.ortho = false});
  final double? focalLength; // mm, for setLensProjection
  final double? fovDegrees; // vertical FoV, for the ultra-wide preset
  final bool ortho; // orthographic projection
}

/// Maps a lens preset name to its [LensParams]. Unknown values fall back to the
/// 70mm default. Pure — no viewer/aspect needed — so a test can assert the
/// mapping without a Filament context.
LensParams lensParamsFor(String preset) {
  switch (preset) {
    case '24mm':
      return const LensParams(focalLength: 24);
    case 'fisheye':
      // Ultra-wide vertical FoV — an exaggerated wide-angle look, NOT a true
      // (mapped) fisheye, which the ubershader can't do.
      return const LensParams(fovDegrees: 120);
    case 'ortho':
      return const LensParams(ortho: true);
    case '70mm':
    default:
      return const LensParams(focalLength: 70);
  }
}

/// A flat shadow-catcher quad (#4) in the model's normalized space.
class GroundPlaneGeometry {
  const GroundPlaneGeometry(this.positions, this.normals, this.indices);

  /// 4 corner vertices, 3 floats each (x,y,z).
  final Float32List positions;

  /// Per-vertex up normal (0,1,0), 3 floats each.
  final Float32List normals;

  /// Two triangles (6 indices) winding CCW when viewed from above (+Y).
  final List<int> indices;
}

/// World-space Y of the model's base (AABB min-Y) after the viewer's fit
/// transform (#4, Efe feedback #3). `_applyMode` centers the model then scales
/// it by [fit] about the origin, so the lowest point lands at
/// `-(sizeY/2)·fit` — NOT `-_kFitRadius` (the bounding-*sphere* radius), which
/// floats the object above the catcher for any model that isn't a vertical
/// stick. [modelSizeY] is the AABB height in the file's units; [fit] is the
/// uniform fit scale `_applyMode` applies. Pure — unit-testable without a GPU.
double groundPlaneWorldY({required double modelSizeY, required double fit}) =>
    -(modelSizeY * 0.5) * fit;

/// Builds a horizontal shadow-catcher quad sitting at [y] (the model's bottom),
/// spanning ±[half] in x and z, with an up normal. The model is normalized so
/// its bounding sphere has radius [_kFitRadius] about the origin; callers pass
/// the AABB-base [y] from [groundPlaneWorldY] (so the object sits ON the floor)
/// and `half = _kFitRadius * 4` (a generous floor for the shadow to land on).
/// Pure — unit-tested without a GPU.
GroundPlaneGeometry buildGroundPlane({required double y, required double half}) {
  final positions = Float32List.fromList(<double>[
    -half, y, -half, // 0
    half, y, -half, // 1
    half, y, half, // 2
    -half, y, half, // 3
  ]);
  final normals = Float32List.fromList(<double>[
    0, 1, 0,
    0, 1, 0,
    0, 1, 0,
    0, 1, 0,
  ]);
  // CCW from above so the up-facing side is front: (0,1,2) + (0,2,3). USHORT
  // typed (matching IndexType.USHORT and the rest of the createGeometry calls).
  final indices = Uint16List.fromList(<int>[0, 1, 2, 0, 2, 3]);
  return GroundPlaneGeometry(positions, normals, indices);
}

// --- CPU pivot ray-cast (#8) -------------------------------------------------
//
// Double-tap sets the orbit pivot to the point on the model under the finger.
// We DON'T use Filament's GPU View.pick: its readback is unverified on this
// Adreno device and risks a native segfault we can't device-test before
// shipping. So picking is pure CPU — build the camera ray from the live camera
// matrices, then intersect the parsed mesh triangles with Möller–Trumbore.

/// Möller–Trumbore ray/triangle intersection. Returns the distance `t` along
/// [dir] (in [dir]'s length units, t > [epsilon]) at the front-or-back hit, or
/// null on a miss / parallel ray. [dir] need not be normalized. Two-sided (we
/// don't cull by winding — OBJ/STL winding is inconsistent). Pure + unit-tested.
double? rayTriangleIntersection(
  Vector3 origin,
  Vector3 dir,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2, {
  double epsilon = 1e-7,
}) {
  final edge1 = v1 - v0;
  final edge2 = v2 - v0;
  final pvec = dir.cross(edge2);
  final det = edge1.dot(pvec);
  if (det.abs() < epsilon) return null; // ray parallel to the triangle
  final invDet = 1.0 / det;
  final tvec = origin - v0;
  final u = tvec.dot(pvec) * invDet;
  if (u < 0.0 || u > 1.0) return null;
  final qvec = tvec.cross(edge1);
  final v = dir.dot(qvec) * invDet;
  if (v < 0.0 || u + v > 1.0) return null;
  final t = edge2.dot(qvec) * invDet;
  if (t <= epsilon) return null; // behind the ray origin
  return t;
}

/// Inputs for the off-isolate nearest-triangle search (#8). All fields are
/// isolate-sendable (typed lists + doubles): the mesh is transformed by the
/// same fit (scale about origin after centering) that `_applyMode` applies, so
/// the ray (already in world space) hits where the model is actually drawn.
class PivotPickRequest {
  const PivotPickRequest({
    required this.positions,
    required this.indices,
    required this.triangleCount,
    required this.fit,
    required this.centerX,
    required this.centerY,
    required this.centerZ,
    required this.ox,
    required this.oy,
    required this.oz,
    required this.dx,
    required this.dy,
    required this.dz,
  });
  final Float32List positions;
  final List<int> indices;
  final int triangleCount;
  final double fit; // uniform fit scale
  final double centerX, centerY, centerZ; // model center (pre-scale)
  final double ox, oy, oz; // ray origin (world)
  final double dx, dy, dz; // ray direction (world, need not be unit)
}

/// Returns the nearest world-space hit point of the request's ray against the
/// transformed mesh, or null if the ray misses every triangle. Top-level so it
/// can run via `compute()` for large meshes; also called inline for small ones.
Vector3? nearestPivotHit(PivotPickRequest r) {
  final origin = Vector3(r.ox, r.oy, r.oz);
  final dir = Vector3(r.dx, r.dy, r.dz);
  final tris = math.min(r.triangleCount, r.indices.length ~/ 3);
  double bestT = double.infinity;
  for (var t = 0; t < tris; t++) {
    final i0 = r.indices[t * 3], i1 = r.indices[t * 3 + 1], i2 = r.indices[t * 3 + 2];
    final a0 = i0 * 3, a1 = i1 * 3, a2 = i2 * 3;
    // World vertex = (p - center) * fit  (matches _applyMode's S·T(-center)).
    final v0 = Vector3(
      (r.positions[a0] - r.centerX) * r.fit,
      (r.positions[a0 + 1] - r.centerY) * r.fit,
      (r.positions[a0 + 2] - r.centerZ) * r.fit,
    );
    final v1 = Vector3(
      (r.positions[a1] - r.centerX) * r.fit,
      (r.positions[a1 + 1] - r.centerY) * r.fit,
      (r.positions[a1 + 2] - r.centerZ) * r.fit,
    );
    final v2 = Vector3(
      (r.positions[a2] - r.centerX) * r.fit,
      (r.positions[a2 + 1] - r.centerY) * r.fit,
      (r.positions[a2 + 2] - r.centerZ) * r.fit,
    );
    final hit = rayTriangleIntersection(origin, dir, v0, v1, v2);
    if (hit != null && hit < bestT) bestT = hit;
  }
  if (!bestT.isFinite) return null;
  return origin + dir * bestT;
}

class _ModelSceneViewState extends State<ModelSceneView> {
  ThermionViewer? _viewer;
  Camera? _camera;
  ThermionAsset? _asset;
  MaterialInstance? _material;

  /// Parsed + de-interleaved model. Retained after upload so render modes can
  /// rebuild the asset (TRIANGLES vs LINES) without re-reading the file.
  _PreparedModel? _model;

  /// Triangle-edge index buffer for wireframe, built lazily from [_model].
  List<int>? _lineIndices;

  /// De-indexed flat-shaded (per-face normal) copy of [_model], built lazily
  /// when flat shading is in effect. See [_effectiveFlat].
  _FlatModel? _flatModel;

  /// Shading preference: 'auto' (default), 'smooth', 'flat'. Auto flat-shades
  /// small models whose file carried no normals (e.g. a 320-tri geosphere —
  /// smooth-shading those makes a soft blob with a polygonal silhouette;
  /// crisp facets match the look of the CPU-rasterized library thumbnail).
  String _shading = 'auto';

  /// Hard cap for flat shading: de-indexing triples vertex data, so very large
  /// models stay smooth even if the user asks for flat.
  static const int _flatMaxTris = 300000;

  bool _viewerReady = false;
  bool _hasModel = false;
  bool _thumbCaptured = false; // one thumbnail per model load
  // Library thumbnails are rasterized on the CPU (see thumbnail_raster.dart),
  // NOT via Thermion's GPU capture() — that crashed the app on device (both the
  // live swapchain AND a dedicated offscreen View+RenderTarget; alpha.4/alpha.6,
  // Samsung Device Care flagged "holdable sıklıkla çöküyor"). The CPU path runs
  // in the parse isolate, never touches Filament's render thread, so it can't
  // stall or crash rendering. Output is encoded to PNG on the UI isolate below.
  static const int _thumbSize = 256; // square thumbnail edge, px

  String _mode = 'solid';
  Color _baseColor = _kNeutral;
  bool _colorPicked = false; // user has chosen a color (vs the neutral default)
  // Current material samples the baked per-material vertex colors (glTF
  // multi-material models; see MeshData.hasVertexColors). While active the
  // baseColorFactor is white so the per-part colors come through unmultiplied.
  bool _vertexColorsActive = false;
  double _currentAlpha = 1.0; // 0.35 in x-ray

  /// Camera lens/projection preset (#9): '70mm' (default), '24mm', 'fisheye'
  /// (ultra-wide) or 'ortho'. Re-applied after every (re)frame because the
  /// ThermionWidget re-applies its own lens projection on texture realloc.
  String _projection = '70mm';

  // --- Texture state. The ENCODED image (PNG/JPEG bytes) is retained so
  // render-mode rebuilds (new material) can re-apply the texture; decoding
  // happens natively via FilamentApp.decodeImage + Texture.setLinearImage —
  // the exact path thermion's own tests exercise. THE device-crash lesson
  // (alpha.28/.29): the gltfio ubershader is a VARIANT ARCHIVE — only a
  // material created with hasBaseColorTexture: true owns the baseColorMap /
  // baseColorIndex parameters, and Filament's setParameter on a missing
  // parameter aborts NATIVELY (uncatchable). So binding happens in _applyMode
  // on the matching variant, never on a live plain material. (Avoid
  // Texture.setImage too: its FFI passes enum .index where native expects
  // .value.) All GPU texture work is best-effort: a failure leaves the model
  // on its plain base color.
  Uint8List? _texEncoded;
  Texture? _texture; // current Filament texture (one at a time)
  TextureSampler? _texSampler; // shared REPEAT/LINEAR sampler, created once

  // Crash-resilient texture-pipeline trace: each native step is written
  // (synchronously, flushed) to a small file BEFORE it runs and the file ends
  // at 'done' on success. If the app dies inside a native call (uncatchable
  // abort), the file names the killer step on the next launch — the
  // share-debug pattern that solved the alpha.13 bug in one device round.
  String? _traceDir;
  Future<void>? _traceInit;
  String? _texCrashStep; // step a previous session died on (skip auto-apply)

  Future<void> _initTrace() => _traceInit ??= () async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          _traceDir = dir.path;
          final f = File('${dir.path}/texture_trace.txt');
          if (f.existsSync()) {
            final c = f.readAsStringSync().trim();
            if (c.isNotEmpty && c != 'done') {
              _texCrashStep = c;
              widget.onTextureCrashDetected?.call(c);
              // Re-arm for the next session; this one skips auto-apply.
              f.writeAsStringSync('done', flush: true);
            }
          }
        } catch (_) {/* tracing is best-effort */}
      }();

  void _trace(String step) {
    final d = _traceDir;
    if (d == null) return;
    try {
      File('$d/texture_trace.txt').writeAsStringSync(step, flush: true);
    } catch (_) {}
  }
  // Adjustable light rig (see _kLightRig): stored entities + the user's
  // intensity multiplier and azimuth rotation (radians, around Y).
  final List<ThermionEntity> _lights = [];
  double _lightIntensity = 1.0;
  double _lightAzimuth = 0.0;
  // Lighting environment preset (Faz C / PO #6): composed on top of the user's
  // intensity/azimuth sliders when the rig is (re)built/(re)aimed.
  EnvLightPreset _envPreset = environmentLightPreset(AppEnvironment.none);

  // --- Ground/contact shadow (#4). Off by default. The shadow-catcher quad
  // and its dedicated overhead castShadows sun are kept OUT of [_lights] so the
  // rig rebuild in _rebuildRig never drops the shadow light. ---
  bool _groundShadow = false;
  ThermionEntity? _shadowLight; // overhead sun that casts the shadow
  ThermionAsset? _groundPlane; // shadow-catcher quad asset
  MaterialInstance? _groundMaterial; // its material — must be destroyed with it
  bool _rebuilding = false;
  String? _pendingMode; // latest mode requested while a rebuild was in flight
  bool _pendingFrame = false; // a reframe (model change) was queued mid-rebuild

  // --- Orbit state: spherical camera around the (panned) model center. ---
  double _azimuth = _isoAzimuth;
  double _elevation = _isoElevation;
  double _radius = 5;
  double _minRadius = 0.5;
  double _maxRadius = 50;
  double _startRadius = 5;
  // Framing distance at which the model fills the view at scale 1.0 — the base
  // for hand-pose zoom (see _setHandPose). Captured when the camera frames.
  double _modelBaseRadius = 5;

  /// Camera pivot, shifted by two-finger pan so the model can be moved up out
  /// from behind the bottom panel (or recentered). Origin = model center.
  final Vector3 _target = Vector3.zero();

  /// Last logical size of the render surface (from the build LayoutBuilder),
  /// used to map a double-tap point to NDC for the pivot ray-cast (#8).
  Size? _lastSize;

  /// Monotonic token so a stale off-isolate pivot result (the user double-tapped
  /// again, or the model changed, before [compute] returned) is ignored.
  int _pivotPickSeq = 0;

  bool _applyingCamera = false;
  bool _cameraDirty = false;

  static const double _isoAzimuth = math.pi / 4;
  static const double _isoElevation = 0.6;
  static const double _elevationLimit = math.pi / 2 - 0.05;
  // Every model is uniformly scaled so its bounding sphere has this radius (in
  // world units), so display size + framing are consistent regardless of the
  // file's authored units (and tiny models don't fall inside the near clip).
  static const double _kFitRadius = 1.0;
  // Hand-mode starts the model this much further than the viewer's default
  // framing, so it doesn't fill the frame and has room to be enlarged.
  static const double _kHandFramingPullback = 1.6;
  static const double _rotSpeed = 0.01; // rad per px
  static const double _panSpeed = 0.0015; // world units per px, scaled by radius
  static const double _xrayAlpha = 0.35;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    _initViewer();
    _load();
  }

  @override
  void didUpdateWidget(ModelSceneView old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath) _load();
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    final viewer = _viewer;
    _viewer = null;
    viewer?.dispose();
    // Textures/samplers are FilamentApp-owned (not torn down with the viewer).
    final tex = _texture;
    _texture = null;
    tex?.destroy().catchError((_) {});
    final sampler = _texSampler;
    _texSampler = null;
    sampler?.dispose().catchError((_) {});
    super.dispose();
  }

  /// Creates the Filament viewer once and applies the scene-wide setup.
  Future<void> _initViewer() async {
    try {
      final viewer = await ThermionFlutterPlugin.createViewer();
      await viewer.setPostProcessing(true);
      await viewer.setAntiAliasing(false, true, false); // FXAA
      // Clear the skybox so the background is TRANSPARENT (Faz C / PO #6):
      // Thermion renders transparent by default, and setBackgroundColor only
      // looked opaque because it builds an opaque skybox. Removing the skybox
      // lets the Flutter EnvironmentBackdrop behind the Thermion texture show
      // through — it now owns the backdrop for ALL environments, including None
      // (where it paints the same flat widget.background colour as before).
      await viewer.removeSkybox();
      // No IBL/skybox is bundled, so lighting is entirely direct. With only a
      // key + fill + rim trio, a low-poly model (e.g. the 8-face octahedron) can
      // still have facets that face away from every light → pure black. Surround
      // the model with six suns (the key/fill/rim plus three dim counter-lights
      // roughly opposite them) so every facet picks up some light — a poor-man's
      // ambient that kills the half-black look without an IBL.
      _lights.clear();
      for (final (x, y, z, inten) in _kLightRig) {
        final e = await viewer.addDirectLight(DirectLight.sun(
          direction:
              _rotatedDir(x, y, z, _lightAzimuth + _envPreset.azimuthBias),
          intensity: inten * _lightIntensity * _envPreset.intensityScale,
          colorTemperature: _envPreset.colorTemperature,
          castShadows: false,
        ));
        _lights.add(e);
      }
      // Filmic tone mapping + a touch of bloom give the render richer, more
      // natural color/contrast than the raw linear output. Best-effort.
      try {
        await viewer.setToneMapper(await ToneMapper.filmic());
        await viewer.setBloom(true, 0.08);
      } catch (_) {/* keep default tone mapping */}
      // Image-based lighting (bundled studio environment) is OFF by default —
      // it overexposed the look, and the directional rig + filmic is the better
      // baseline. The user opts in via the Render panel's Environment picker
      // (see _setEnvironment), which loads/removes the IBL per the picked preset.
      final camera = await viewer.getActiveCamera();
      if (!mounted) {
        await viewer.dispose();
        return;
      }
      _viewer = viewer;
      _camera = camera;
      _viewerReady = true;
      // Seed the indirect light for the starting environment (default None →
      // the zero-GPU constant ambient floor, so the very first model isn't shown
      // with pure-black undersides before any env is picked).
      await _applyEnvIbl();
      if (_model != null) await _applyMode(_mode, frame: true);
      // Apply the lens preset (#9) once the camera exists. _applyMode(frame:)
      // re-applies it after framing too; this covers the no-model-yet path.
      await _applyProjection();
    } catch (e) {
      if (mounted) widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  Future<void> _load() async {
    widget.onStatus(const ModelSceneStatus(loading: true));
    try {
      final prepared = await compute(
        _prepareModelEntry,
        _ParseRequest(
          widget.filePath,
          widget.format,
          thumbSize: _thumbSize,
          // Thumbnail framing is the library's, NOT the viewer camera's iso —
          // one source of truth (kThumbnail*) so every model is framed uniformly.
          thumbAzimuth: kThumbnailAzimuth,
          thumbElevation: kThumbnailElevation,
          thumbBgColor: _argb(widget.background),
          thumbSurfaceColor: _argb(_baseColor),
        ),
      );
      if (!mounted) return;
      _model = prepared;
      _lineIndices = null; // invalidate the previous model's wireframe cache
      _flatModel = null; // and its flat-shading cache
      _thumbCaptured = false;
      // Show the model in its own colour if it carries one (e.g. a glTF
      // material). The user can still re-pick from the Render panel.
      if (prepared.baseColorArgb != null) {
        _baseColor = Color(prepared.baseColorArgb!);
      }
      // Texture state belongs to one model: drop the previous model's texture
      // (destroyed after the rebuild below replaces the material that samples
      // it), and adopt this model's own embedded texture if it has one (e.g. a
      // textured GLB) so the rebuild binds it.
      final staleTex = _texture;
      _texture = null;
      await _initTrace();
      // Skip the embedded-texture auto-apply if a previous session died in the
      // texture pipeline (crash-loop protection) — the model still opens plain.
      _texEncoded = _texCrashStep == null ? prepared.textureBytes : null;
      if (_viewerReady) await _applyMode(_mode, frame: true);
      // If the ground shadow is on and the model changed in place, re-base the
      // shadow-catcher at the NEW model's bottom (its sizeY differs). Reuses the
      // same guarded enable/disable path — best-effort, no new crash surface.
      if (_groundShadow && _viewerReady) {
        await _disableGroundShadow();
        await _enableGroundShadow();
      }
      if (staleTex != null) {
        try {
          await staleTex.destroy();
        } catch (_) {}
      }
      // Thumbnail was rasterized off-isolate alongside the parse (CPU, no GPU).
      // Encode it to PNG on the UI isolate and hand it to the host to persist.
      await _maybeEmitThumbnail(prepared);
    } catch (e) {
      if (!mounted) return;
      widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  /// ARGB int (0xAARRGGBB) for a [Color], via its 0..1 component channels.
  static int _argb(Color c) =>
      ((c.a * 255).round() << 24) |
      ((c.r * 255).round() << 16) |
      ((c.g * 255).round() << 8) |
      (c.b * 255).round();

  /// The user's picked color as sRGB 0xAARRGGBB, or null when untouched or a
  /// texture is shown — see [ModelSceneController.pickedColorArgb]. The decision
  /// is the pure [arPickedColorArgb] so it's unit-tested.
  int? get _pickedColorArgb => arPickedColorArgb(
        colorPicked: _colorPicked,
        hasTexture: _texEncoded != null,
        baseColorArgb: _argb(_baseColor),
      );

  /// Builds (or rebuilds) the on-screen asset for [mode], optionally framing the
  /// camera to it (on first load / model change). Coalesces rapid mode taps.
  Future<void> _applyMode(String mode, {bool frame = false}) async {
    final viewer = _viewer;
    final p = _model;
    if (viewer == null || p == null) return;
    if (_rebuilding) {
      _pendingMode = mode; // apply once the in-flight rebuild finishes
      if (frame) _pendingFrame = true; // don't lose a model-change reframe
      return;
    }
    _rebuilding = true;
    try {
      _mode = mode;
      if (frame) widget.onStatus(const ModelSceneStatus(loading: true));

      final old = _asset;
      final oldMaterial = _material;
      if (old != null) {
        await viewer.destroyAsset(old);
        _asset = null;
        _material = null;
      }
      // destroyAsset frees the asset's vertex/index buffers but NOT the borrowed
      // MaterialInstance (verified in Thermion's native GeometrySceneAsset
      // destructor — it never touches _materialInstances). Without this destroy,
      // every model load AND every render-mode / shading / texture / colour
      // rebuild orphaned a MaterialInstance in GPU memory — they accumulated for
      // the whole session (the device GRAPHICS bucket climbed and never dropped
      // on switch: a cube loaded after heavy models read 358 MB). Destroy AFTER
      // destroyAsset so it's no longer bound to a live renderable. The shared
      // ubershader archive material is untouched, so there is no double-free.
      if (oldMaterial != null) {
        try {
          await oldMaterial.destroy();
        } catch (_) {/* best-effort */}
      }

      final bool wireframe = mode == 'wireframe';
      final bool xray = mode == 'xray';
      _currentAlpha = xray ? _xrayAlpha : 1.0;

      // Baked per-material vertex colors (glTF multi-material models): sampled
      // in the triangle modes until the user picks their own color — the pick
      // replaces the per-part colors (see _setColor), it doesn't tint them.
      final bool vertexColors = !wireframe && p.colors != null && !_colorPicked;
      _vertexColorsActive = vertexColors;

      // Geometry: triangles for solid/x-ray, line topology for wireframe.
      final Geometry geometry;
      if (wireframe) {
        final lines = _lineIndices ??= _buildLineIndices(p);
        geometry = Geometry(
          p.positions,
          lines,
          primitiveType: PrimitiveType.LINES,
          indexType: p.indexType,
        );
      } else if (_effectiveFlat(p)) {
        final flat = _flatModel ??= _buildFlatModel(p);
        geometry = Geometry(
          flat.positions,
          flat.indices,
          normals: flat.normals,
          uvs: flat.uvs,
          colors: vertexColors ? flat.colors : null,
          indexType: flat.indexType,
        );
      } else {
        geometry = Geometry(
          p.positions,
          p.indices,
          normals: p.normals,
          uvs: p.uvs,
          colors: vertexColors ? p.colors : null,
          indexType: p.indexType,
        );
      }

      // GPU texture first (solid/x-ray only): the ubershader is a VARIANT
      // ARCHIVE — a material instance only *has* the baseColorMap/baseColorIndex
      // parameters when created with hasBaseColorTexture: true, and Filament's
      // MaterialInstance::setParameter on a missing parameter ABORTS natively
      // (the alpha.28/.29 device crash). So the texture must exist before the
      // material is created, and binding happens on the matching variant.
      Texture? tex;
      if (!wireframe && _texEncoded != null) {
        await _initTrace();
        try {
          tex = _texture ??= await _createGpuTexture(_texEncoded!);
        } catch (_) {/* fall back to the untextured variant */}
        // A graceful (caught) failure is not a crash — close the trace.
        if (tex == null) _trace('done');
      }
      final bool textured = tex != null;

      // Material: lit ubershader for solid, blended for x-ray, unlit for the
      // wireframe (line shading is meaningless).
      if (textured) _trace('createUbershaderMaterialInstance(textured)');
      final material = await FilamentApp.instance!.createUbershaderMaterialInstance(
        unlit: wireframe,
        alphaMode: xray ? AlphaMode.BLEND : AlphaMode.OPAQUE,
        // Double-sided so back faces are lit with flipped normals — otherwise
        // the inside/under faces (OBJ/STL winding is inconsistent) stay black
        // and the color doesn't read on every surface.
        doubleSided: true,
        hasVertexColors: vertexColors,
        hasBaseColorTexture: textured,
        baseColorUV: 0,
      );
      await material.setCullingMode(CullingMode.NONE);
      if (xray) await material.setTransparencyMode(TransparencyMode.DEFAULT);
      if (textured) {
        try {
          _trace('createTextureSampler');
          _texSampler ??= await FilamentApp.instance!.createTextureSampler(
            wrapS: TextureWrapMode.REPEAT,
            wrapT: TextureWrapMode.REPEAT,
          );
          final uber = UbershaderMaterialInstance(material);
          _trace('setBaseColorTexture');
          await uber.setBaseColorTexture(tex, _texSampler!);
          _trace('setBaseColorUV');
          await uber.setBaseColorUV(0); // sample baseColorMap with UV set 0
          _trace('done');
        } catch (_) {
          _trace('done'); // caught — not a crash
        }
      }
      await _applyColorTo(material);

      final asset = await viewer.createGeometry(
        geometry,
        materialInstances: [material],
        // _applyMode rebuilds the Geometry from _model on EVERY mode switch, so
        // Filament's retained CPU-side source copy was never actually reused — it
        // just piled up as a per-model high-water in the NATIVE/Unknown bucket
        // (~139 MB after a heavy model). Release it; the GPU buffers are unaffected.
        releaseSourceData: true,
      );
      _asset = asset;
      _material = material;

      // Normalize display size: center the model AND uniformly scale it so its
      // bounding sphere has a fixed radius (_kFitRadius), regardless of the
      // file's authored units. Without this, a model authored in metres at real
      // toy scale (e.g. the Khronos ToyCar — bounds ~0.04 units) frames at a
      // camera distance smaller than the near-clip plane and renders BLANK,
      // while a unit-scale model fills the view. Scaling to a constant size
      // makes framing consistent for every model and kills the near-clip
      // blank-out. Order S·T(-center): translate the centre to the origin, then
      // scale about it.
      final modelRadius = p.camDistance / 3.0;
      final fit = modelRadius > 1e-9 ? _kFitRadius / modelRadius : 1.0;
      await FilamentApp.instance!.setTransform(
        asset.entity,
        Matrix4.identity()
          ..scaleByDouble(fit, fit, fit, 1)
          ..translateByVector3(Vector3(-p.centerX, -p.centerY, -p.centerZ)),
      );
      await viewer.addToScene(asset);

      if (frame) {
        // The model is normalized to _kFitRadius (see setTransform above), so
        // framing is fixed in normalized units — same comfortable size for any
        // model, and the camera always sits well beyond the near-clip plane.
        const fitCamDistance = _kFitRadius * 3.0;
        _radius = fitCamDistance;
        _startRadius = _radius;
        _modelBaseRadius = fitCamDistance;
        _minRadius = _kFitRadius * 0.4;
        _maxRadius = fitCamDistance * 5.0;
        _azimuth = _isoAzimuth;
        _elevation = _isoElevation;
        _target.setZero();
        await _applyCameraNow();
        // Re-apply the lens preset (#9): ThermionWidget re-applies its own
        // setLensProjection on every texture realloc (which this rebuild can
        // trigger), clobbering ortho/fisheye — so reassert it after framing.
        await _applyProjection();
      }

      if (!_hasModel || frame) {
        _hasModel = true;
        if (mounted) setState(() {});
      }
      if (frame) {
        widget.onStatus(ModelSceneStatus(
          loading: false,
          verts: p.vertexCount,
          tris: p.triangleCount,
          parseMs: p.parseMs,
        ));
        // The library thumbnail is rasterized on the CPU off the load path (see
        // _load → _maybeEmitThumbnail), not captured from the GPU view here.
      }
    } catch (e) {
      if (mounted) widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    } finally {
      _rebuilding = false;
      final next = _pendingMode;
      final pframe = _pendingFrame;
      _pendingMode = null;
      _pendingFrame = false;
      // Re-apply when the mode changed OR a model-change reframe was queued. The
      // model can change with the SAME mode (Next/Prev) — without the pframe
      // check that rebuild + reframe would be silently dropped, leaving the new
      // model un-framed (tiny) in the reused viewer.
      if (next != null && (next != _mode || pframe)) {
        await _applyMode(next, frame: pframe);
      }
    }
  }

  /// Builds the line-pair index buffer (3 edges per triangle) for wireframe.
  List<int> _buildLineIndices(_PreparedModel p) {
    final tri = p.indices;
    final triCount = tri.length ~/ 3;
    final out = p.indexType == IndexType.USHORT
        ? Uint16List(triCount * 6)
        : Uint32List(triCount * 6);
    var w = 0;
    for (var t = 0; t < triCount; t++) {
      final a = tri[t * 3], b = tri[t * 3 + 1], c = tri[t * 3 + 2];
      out[w++] = a;
      out[w++] = b;
      out[w++] = b;
      out[w++] = c;
      out[w++] = c;
      out[w++] = a;
    }
    return out;
  }

  // --- Camera control -------------------------------------------------------

  /// Camera offset from the pivot, on the orbit sphere.
  Vector3 _orbitOffset() {
    final ce = math.cos(_elevation);
    return Vector3(
      _radius * ce * math.sin(_azimuth),
      _radius * math.sin(_elevation),
      _radius * ce * math.cos(_azimuth),
    );
  }

  Vector3 _orbitPosition() => _target + _orbitOffset();

  Future<void> _applyCameraNow() async {
    final cam = _camera;
    if (cam == null) return;
    await cam.lookAt(_orbitPosition(), focus: _target, up: Vector3(0, 1, 0));
  }

  void _requestCamera() {
    _cameraDirty = true;
    if (_applyingCamera) return;
    _pumpCamera();
  }

  Future<void> _pumpCamera() async {
    final cam = _camera;
    if (cam == null) return;
    _applyingCamera = true;
    try {
      while (_cameraDirty) {
        _cameraDirty = false;
        await cam.lookAt(_orbitPosition(), focus: _target, up: Vector3(0, 1, 0));
      }
    } finally {
      _applyingCamera = false;
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startRadius = _radius;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.scale != 1.0) {
      _radius = (_startRadius / d.scale).clamp(_minRadius, _maxRadius);
    }
    final dp = d.focalPointDelta;
    if (dp != Offset.zero) {
      if (d.pointerCount >= 2) {
        // Two-finger drag → pan the pivot (move the model in-frame, e.g. up out
        // from behind the bottom panel). Translate along the camera's right/up
        // axes, scaled by radius so it feels consistent at any zoom.
        final forward = (-_orbitOffset()).normalized();
        final right = forward.cross(Vector3(0, 1, 0));
        if (right.length2 > 1e-9) {
          right.normalize();
          final camUp = right.cross(forward)..normalize();
          final k = _panSpeed * _radius;
          _target
            ..add(right * (-dp.dx * k))
            ..add(camUp * (dp.dy * k));
        }
      } else {
        // One finger → orbit.
        _azimuth -= dp.dx * _rotSpeed;
        _elevation = (_elevation + dp.dy * _rotSpeed)
            .clamp(-_elevationLimit, _elevationLimit);
      }
    }
    _requestCamera();
  }

  Future<void> _setPreset(String preset) async {
    switch (preset) {
      case 'front':
        _azimuth = 0;
        _elevation = 0;
      case 'top':
        _azimuth = 0;
        _elevation = _elevationLimit;
      case 'side':
        _azimuth = math.pi / 2;
        _elevation = 0;
      case 'iso':
      default:
        _azimuth = _isoAzimuth;
        _elevation = _isoElevation;
    }
    _target.setZero(); // recenter when snapping to a preset
    await _applyCameraNow();
  }

  // --- Pivot ray-cast (#8): double-tap to set the orbit pivot ---------------

  /// Default vertical field-of-view (radians) used to build the pick ray. The
  /// live lens preset (#9) varies the actual projection, but ~36° is a sane
  /// middle value for the 70mm default; pivot precision is device-tunable, so
  /// if double-tap picking lands slightly off on a given panel, nudge this (and
  /// the NDC mapping) rather than chasing the exact Filament projection matrix.
  static const double _kPickVfov = 36.0 * math.pi / 180.0;

  /// Triangle-count threshold above which the nearest-triangle search runs in a
  /// background isolate via [compute] (keeps the UI thread responsive on big
  /// meshes); smaller meshes are intersected inline.
  static const int _kPickInlineMaxTris = 20000;

  /// Double-tap handler (#8): casts a ray from the LIVE orbit camera through the
  /// tapped point and sets the orbit pivot ([_target]) to the nearest point on
  /// the model. A miss (tap on empty background) is a no-op.
  ///
  /// [localLogical] is the tap position in the widget's local logical
  /// coordinates (from onDoubleTapDown). The ray is built in WORLD space, where
  /// the model is drawn after _applyMode's fit transform (center then uniform
  /// scale), so the same transform is baked into the [PivotPickRequest].
  Future<void> _pickPivot(Offset localLogical) async {
    final p = _model;
    final size = _lastSize;
    if (p == null || size == null) return;
    if (size.width <= 0 || size.height <= 0) return;
    if (p.triangleCount <= 0 || p.indices.length < 3) return;

    // Camera basis from the live orbit camera (matches _applyCameraNow's
    // lookAt(eye=_orbitPosition(), focus=_target, up=+Y)).
    final eye = _orbitPosition();
    final forward = (_target - eye);
    if (forward.length2 < 1e-12) return;
    forward.normalize();
    final right = forward.cross(Vector3(0, 1, 0));
    if (right.length2 < 1e-12) return; // looking straight up/down — bail
    right.normalize();
    final camUp = right.cross(forward)..normalize();

    // Tapped point → normalized device coords in [-1, 1]. y is flipped because
    // screen y grows downward while NDC y grows up.
    final ndcX = (localLogical.dx / size.width) * 2.0 - 1.0;
    final ndcY = 1.0 - (localLogical.dy / size.height) * 2.0;
    final aspect = size.width / size.height;
    final tanHalf = math.tan(_kPickVfov / 2.0);

    // Ray direction through the tapped pixel (need not be normalized for the
    // Möller–Trumbore test, but we normalize so `t` reads as a world distance).
    final dir = (forward +
            right * (ndcX * tanHalf * aspect) +
            camUp * (ndcY * tanHalf))
        .normalized();

    // Bake in the same fit transform _applyMode applies: world = (p-center)*fit
    // where fit = _kFitRadius / (camDistance/3).
    final modelRadius = p.camDistance / 3.0;
    final fit = modelRadius > 1e-9 ? _kFitRadius / modelRadius : 1.0;
    final req = PivotPickRequest(
      positions: p.positions,
      indices: p.indices,
      triangleCount: p.triangleCount,
      fit: fit,
      centerX: p.centerX,
      centerY: p.centerY,
      centerZ: p.centerZ,
      ox: eye.x,
      oy: eye.y,
      oz: eye.z,
      dx: dir.x,
      dy: dir.y,
      dz: dir.z,
    );

    final seq = ++_pivotPickSeq;
    Vector3? hit;
    if (p.triangleCount > _kPickInlineMaxTris) {
      hit = await compute(nearestPivotHit, req);
    } else {
      hit = nearestPivotHit(req);
    }
    // Drop the result if we were disposed, the model changed, or a newer tap
    // superseded this one while compute() was running.
    if (!mounted || seq != _pivotPickSeq || !identical(_model, p)) return;
    if (hit == null) return; // missed every triangle — leave the pivot put

    // Clamp the new pivot near the origin so a grazing hit on a huge stray
    // triangle can't fling the camera target out of frame (the model is
    // normalized to ~_kFitRadius about the origin).
    const maxOffset = _kFitRadius * 2.0;
    if (hit.length > maxOffset) hit.scale(maxOffset / hit.length);
    _target.setFrom(hit);
    _requestCamera();
  }

  // --- Lens / projection presets (#9) ---------------------------------------

  /// Switches the camera lens/projection [p] ('70mm' | '24mm' | 'fisheye' |
  /// 'ortho'): records it on the state (so reframes re-assert it) and applies
  /// it now. SharedPreferences persistence is the host screen's job.
  Future<void> _setProjection(String p) async {
    _projection = p;
    await _applyProjection();
  }

  /// Applies the active [_projection] preset to the camera. Best-effort: a
  /// failure leaves the previous projection in place (no crash). The aspect is
  /// read live from the physical viewport so the framing isn't stretched.
  Future<void> _applyProjection() async {
    final cam = _camera;
    final viewer = _viewer;
    if (cam == null || viewer == null) return;
    try {
      final vp = await viewer.view.getViewport();
      if (vp.width <= 0 || vp.height <= 0) return;
      final aspect = vp.width / vp.height;
      final lens = lensParamsFor(_projection);
      if (lens.ortho) {
        // Orthographic: size the half-height to comfortably contain the model
        // (normalized to _kFitRadius about the origin) with a little margin,
        // then widen by aspect so it isn't stretched.
        final h = _kFitRadius * 1.2;
        final w = h * aspect;
        await cam.setProjection(
            Projection.Orthographic, -w, w, -h, h, 0.1, 100.0);
      } else if (lens.fovDegrees != null) {
        // Ultra-wide vertical FoV (the "fisheye" preset — exaggerated wide
        // angle, NOT a true fisheye projection).
        await cam.setProjectionFromVerticalFieldOfView(
            lens.fovDegrees!, 0.1, 100.0, aspect);
      } else {
        await cam.setLensProjection(
          near: 0.1,
          far: 100.0,
          aspect: aspect,
          focalLength: lens.focalLength!,
        );
      }
    } catch (_) {/* keep the prior projection */}
  }

  // --- Ground/contact shadow (#4) -------------------------------------------

  /// Toggles the ground/contact shadow. Best-effort + crash-resilient: this
  /// device is an Adreno (S26 Ultra) with a history of GPU segfaults, so the
  /// whole setup is wrapped — a throw degrades to "no shadow" rather than
  /// crashing the viewer.
  Future<void> _setGroundShadow(bool on) async {
    if (on == _groundShadow) return;
    _groundShadow = on;
    if (on) {
      await _enableGroundShadow();
    } else {
      await _disableGroundShadow();
    }
  }

  /// Turns shadows on, adds a dedicated castShadows sun aimed to match the
  /// lighting (kept out of [_lights]) and lays a shadow-catcher quad at the
  /// model's BASE so the object visibly sits ON the floor (Efe feedback #3).
  Future<void> _enableGroundShadow() async {
    final viewer = _viewer;
    if (viewer == null) return;
    try {
      await viewer.setShadowsEnabled(true);
      // Dedicated shadow sun, aimed along the dominant key light so the cast
      // shadow falls AWAY from it (consistent with the rig + environment), at an
      // intensity that tracks the user's brightness. Kept OUT of _lights so
      // _rebuildRig's remove/re-add loop can't drop it.
      await _aimShadowLight();
      if (_groundPlane == null) {
        // Quad at the model's AABB base in world space — the model is centered
        // then scaled by `fit` about the origin, so its lowest point is at
        // -(sizeY/2)·fit (NOT -_kFitRadius, the bounding-sphere radius, which
        // would float the object). Spans a generous floor for the shadow.
        final p = _model;
        final double groundY;
        if (p != null && p.camDistance > 1e-9) {
          final modelRadius = p.camDistance / 3.0;
          final fit = modelRadius > 1e-9 ? _kFitRadius / modelRadius : 1.0;
          groundY = groundPlaneWorldY(modelSizeY: p.sizeY, fit: fit);
        } else {
          groundY = -_kFitRadius; // no model yet — fall back to the old place
        }
        final g = buildGroundPlane(y: groundY, half: _kFitRadius * 4);
        final geometry = Geometry(
          g.positions,
          g.indices,
          normals: g.normals,
          indexType: IndexType.USHORT,
        );
        // A pragmatic shadow-catcher (NOT a true transparent one): a lit quad
        // tinted to the background, slightly darkened, so it reads as floor and
        // the cast shadow shows on it without an obvious seam.
        final material =
            await FilamentApp.instance!.createUbershaderMaterialInstance(
          doubleSided: true,
        );
        await material.setCullingMode(CullingMode.NONE);
        final bg = widget.background;
        const k = 0.82; // darken the background a touch
        await material.setParameterFloat4(
          'baseColorFactor',
          _srgbToLinear(bg.r * k),
          _srgbToLinear(bg.g * k),
          _srgbToLinear(bg.b * k),
          1.0,
        );
        final plane = await viewer.createGeometry(
          geometry,
          materialInstances: [material],
          releaseSourceData: true,
        );
        _groundPlane = plane;
        _groundMaterial = material;
        await viewer.addToScene(plane);
      }
    } catch (_) {
      // GPU rejected the shadow setup — leave the model rendering normally.
      _groundShadow = false;
    }
  }

  /// Removes the shadow-catcher quad + overhead sun and disables shadows.
  Future<void> _disableGroundShadow() async {
    final viewer = _viewer;
    if (viewer == null) return;
    try {
      final plane = _groundPlane;
      final planeMat = _groundMaterial;
      _groundPlane = null;
      _groundMaterial = null;
      if (plane != null) await viewer.destroyAsset(plane);
      // Free the catcher's MaterialInstance too (destroyAsset doesn't) — same
      // leak as the model path; otherwise each shadow toggle / model switch with
      // shadow on orphans one.
      if (planeMat != null) {
        try {
          await planeMat.destroy();
        } catch (_) {/* best-effort */}
      }
      final light = _shadowLight;
      _shadowLight = null;
      if (light != null) await viewer.removeLight(light);
      await viewer.setShadowsEnabled(false);
    } catch (_) {/* best-effort teardown */}
  }

  /// (Re)creates the ground-shadow sun so the cast shadow stays CONSISTENT with
  /// the lighting (Efe feedback #3): it points along the dominant key light
  /// ([_kLightRig]`[0]`) rotated by the SAME composed azimuth the rig uses
  /// (`_lightAzimuth + _envPreset.azimuthBias`) — so the shadow falls away from
  /// the key — and its intensity tracks `_lightIntensity` (× the env scale).
  ///
  /// Thermion has no runtime intensity setter (see [_rebuildRig]), so changing
  /// brightness means remove + re-add; the direction folds in on the same pass.
  /// No-op (and does not re-enable) when the shadow is off. Best-effort: a GPU
  /// reject leaves the previous shadow sun (or none) in place — never crashes.
  Future<void> _aimShadowLight() async {
    final viewer = _viewer;
    if (viewer == null || !_groundShadow) return;
    try {
      final old = _shadowLight;
      _shadowLight = null;
      if (old != null) await viewer.removeLight(old);
      final (kx, ky, kz, _) = _kLightRig[0];
      final dir = groundShadowSunDirection(
        keyX: kx,
        keyY: ky,
        keyZ: kz,
        azimuth: _lightAzimuth + _envPreset.azimuthBias,
      );
      _shadowLight = await viewer.addDirectLight(DirectLight.sun(
        direction: Vector3(dir.x, dir.y, dir.z),
        intensity: groundShadowSunIntensity(
          lightIntensity: _lightIntensity,
          envIntensityScale: _envPreset.intensityScale,
        ),
        castShadows: true,
      ));
    } catch (_) {/* keep whatever shadow sun (or none) we had */}
  }

  /// Drives the framing from a hand-gesture pose (F4). Maps the controller's
  /// model-space pose onto the orbit camera: [yaw] → azimuth (the model appears
  /// to spin with the wrist), [scale] → distance (≥1 zooms in / bigger), and
  /// [tx]/[ty] (normalized −1..1) → an in-frame pan via the camera right/up axes.
  void _setHandPose(double yaw, double scale, double tx, double ty) {
    _azimuth = _isoAzimuth - yaw;
    _elevation = _isoElevation;
    final s = scale.clamp(0.25, 4.0);
    // Start pulled back from the viewer's tight default framing (×1.6) so the
    // model has breathing room in hand mode — it fills the frame otherwise, and
    // there's nowhere to "grow" it. Two-hand stretch (s>1) zooms back in.
    _radius =
        (_modelBaseRadius * _kHandFramingPullback / s).clamp(_minRadius, _maxRadius);
    // Pan basis from the (just-set) orbit orientation.
    _target.setZero();
    final forward = (-_orbitOffset()).normalized();
    final right = forward.cross(Vector3(0, 1, 0));
    if (right.length2 > 1e-9) {
      right.normalize();
      final camUp = right.cross(forward)..normalize();
      final k = _modelBaseRadius * 0.5; // full -1..1 ≈ half the framing distance
      _target
        ..add(right * (tx * k))
        ..add(camUp * (ty * k));
    }
    _requestCamera();
  }

  /// Writes the current base color (sRGB → linear) into [mi] at the mode alpha.
  /// While a texture or the baked per-material vertex colors are active the
  /// factor is white so the model's own colors come through unmultiplied.
  Future<void> _applyColorTo(MaterialInstance mi) async {
    final textured = _texture != null && _mode != 'wireframe';
    final white = textured || _vertexColorsActive;
    await mi.setParameterFloat4(
      'baseColorFactor',
      white ? 1.0 : _srgbToLinear(_baseColor.r),
      white ? 1.0 : _srgbToLinear(_baseColor.g),
      white ? 1.0 : _srgbToLinear(_baseColor.b),
      _currentAlpha,
    );
    // The gltfio ubershader defaults metallicFactor to 1.0 (glTF default). With
    // the skybox removed (Faz C) and IBL off by default, a metal has nothing to
    // reflect → the model renders BLACK (only sharp specular from the directional
    // rig — the "glossy black car" symptom). Force a dielectric so the rig lights
    // it diffusely as the neutral colour. metallic/roughness are core PBR params
    // present in EVERY ubershader variant (baseColorFactor sets fine above), so
    // this can't hit the missing-parameter native abort (alpha.28 lesson).
    await mi.setParameterFloat('metallicFactor', 0.0);
    await mi.setParameterFloat('roughnessFactor', 0.6);
  }

  Future<void> _setColor(Color color) async {
    _baseColor = color;
    _colorPicked = true;
    // Picking a color switches the surface back to flat color (texture off) —
    // baseColorFactor and baseColorMap are mutually exclusive in the UI.
    if (_texEncoded != null) {
      await _clearTexture();
      return;
    }
    // Baked per-material vertex colors need a rebuild, not a live factor swap:
    // the material variant that samples COLOR would only *tint* them (blue on a
    // red part reads black). The rebuild drops the variant (_colorPicked is now
    // true) so the picked color replaces the per-part colors.
    if (_vertexColorsActive) {
      await _applyMode(_mode);
      return;
    }
    final mi = _material;
    if (mi != null) await _applyColorTo(mi);
  }

  /// Rotates a base light direction [x],[y],[z] around the Y axis by [az] rad
  /// (so the whole rig swings to relight the model from a new angle).
  Vector3 _rotatedDir(double x, double y, double z, double az) {
    final ca = math.cos(az), sa = math.sin(az);
    return Vector3(x * ca + z * sa, y, -x * sa + z * ca)..normalize();
  }

  /// Applies the lighting environment [env] (Faz C / PO #6): adopts its
  /// [EnvLightPreset], RE-APPLIES the directional rig so the preset's intensity
  /// scale / colour temperature / azimuth bias take effect (composed on top of
  /// the user's sliders), and loads or removes the bundled studio IBL per the
  /// preset's `iblAmount`. The visible backdrop is a separate Flutter layer
  /// (EnvironmentBackdrop); this owns only the renderer's lighting.
  ///
  /// Best-effort + Adreno-safe: the whole thing is wrapped so a GPU reject
  /// degrades to the previous lighting rather than crashing. Call on selection
  /// — (re)loading the KTX + rebuilding the rig isn't free.
  Future<void> _setEnvironment(AppEnvironment env) async {
    final v = _viewer;
    if (v == null) return;
    _envPreset = environmentLightPreset(env);
    try {
      // Re-apply the rig with the new preset (rebuild bakes the intensity scale
      // + colour temperature; the re-aim folds in the azimuth bias). The
      // _setLightAzimuth call also re-aims the ground-shadow sun for the new
      // preset (consistent shadow direction/strength — no-op if shadow off).
      await _rebuildRig();
      await _setLightAzimuth(_lightAzimuth);
      await _applyEnvIbl();
    } catch (_) {/* keep the directional rig as the only light */}
  }

  /// Applies the indirect light for the active [_envPreset]. The high-amount
  /// presets (Sky/Studio) load the bundled studio cubemap IBL; the no-IBL presets
  /// (None/Café) instead get the zero-texture CONSTANT ambient ([_kAmbientSH]) so
  /// downward facets are lifted out of pure black without the cubemap's ~70 MB
  /// GPU cost. Both loadIbl and removeIbl first destroy whatever IBL is already
  /// in the scene (removeIbl reads it back via getIndirectLight), so switching
  /// environments never leaks or double-sets. Best-effort + Adreno-safe: a GPU
  /// reject degrades to the directional rig instead of crashing.
  Future<void> _applyEnvIbl() async {
    final v = _viewer;
    if (v == null) return;
    try {
      final amt = _envPreset.iblAmount;
      if (amt > 0.01) {
        await v.loadIbl('asset://assets/env/studio_ibl.ktx',
            intensity: amt * 36000);
      } else {
        await v.removeIbl(); // clear+destroy any prior IBL (studio or ambient)
        final scene = await v.view.getScene();
        final ambient = await FFIIndirectLight.fromIrradianceHarmonics(
          _kAmbientSH,
          intensity: _kAmbientFloorLux,
        );
        await scene.setIndirectLight(ambient);
      }
    } catch (_) {/* keep the directional rig as the only light — Adreno-safe */}
  }

  /// Re-aims every light for a new rig azimuth (cheap — direction only, no
  /// re-creation). Live as the angle slider drags. The active environment's
  /// [EnvLightPreset.azimuthBias] is composed on top of the user's angle so the
  /// café side-key swing survives a relight.
  Future<void> _setLightAzimuth(double az) async {
    _lightAzimuth = az;
    final v = _viewer;
    if (v == null) return;
    for (var i = 0; i < _lights.length && i < _kLightRig.length; i++) {
      final (x, y, z, _) = _kLightRig[i];
      await v.setLightDirection(
          _lights[i], _rotatedDir(x, y, z, az + _envPreset.azimuthBias));
    }
    // Keep the cast shadow consistent with the relit rig (no-op if shadow off).
    await _aimShadowLight();
  }

  /// Applies a new brightness multiplier to the EXISTING rig (and the cast-
  /// shadow sun) in place via [LightManager.setIntensity] — no remove/re-add,
  /// so it is cheap enough to drive live while the slider is dragged. (Thermion
  /// DOES expose a runtime intensity setter; an earlier note here claimed it
  /// didn't, which forced a needless rig rebuild applied only on release — the
  /// reason brightness "felt" like it did nothing while dragging.)
  void _setLightIntensity(double factor) {
    _lightIntensity = factor.clamp(0.2, 2.5);
    _applyLiveIntensity();
  }

  /// Writes [_lightIntensity] (composed with the active env scale) straight to
  /// every live sun — and the separate ground-shadow sun — through the
  /// LightManager. Synchronous and allocation-free: safe to call on every drag
  /// tick. A brightness move never changes the shadow sun's *direction*, so only
  /// its intensity is updated here (re-aiming stays in [_aimShadowLight]).
  void _applyLiveIntensity() {
    final lm = FilamentApp.instance?.lightManager;
    if (lm == null) return;
    for (var i = 0; i < _lights.length && i < _kLightRig.length; i++) {
      final (_, _, _, inten) = _kLightRig[i];
      lm.setIntensity(
          _lights[i], inten * _lightIntensity * _envPreset.intensityScale);
    }
    final sl = _shadowLight;
    if (sl != null && _groundShadow) {
      lm.setIntensity(
          sl,
          groundShadowSunIntensity(
            lightIntensity: _lightIntensity,
            envIntensityScale: _envPreset.intensityScale,
          ));
    }
  }

  /// Remove + re-add the six-sun rig at the CURRENT user intensity/azimuth
  /// COMPOSED with the active [_envPreset] (Faz C / PO #6): each sun's intensity
  /// is `base · userIntensity · preset.intensityScale`, its azimuth is the
  /// user's angle plus `preset.azimuthBias`, and its colour temperature is the
  /// preset's (null = neutral). A full rebuild is needed when the colour
  /// temperature or azimuth-bias change (the environment picker); a pure
  /// brightness move takes the cheaper in-place [_applyLiveIntensity] path.
  Future<void> _rebuildRig() async {
    final v = _viewer;
    if (v == null) return;
    for (final e in _lights) {
      await v.removeLight(e);
    }
    _lights.clear();
    for (final (x, y, z, inten) in _kLightRig) {
      final e = await v.addDirectLight(DirectLight.sun(
        direction: _rotatedDir(x, y, z, _lightAzimuth + _envPreset.azimuthBias),
        intensity: inten * _lightIntensity * _envPreset.intensityScale,
        colorTemperature: _envPreset.colorTemperature,
        castShadows: false,
      ));
      _lights.add(e);
    }
  }

  void _setRenderMode(String mode) {
    _applyMode(mode);
  }

  // --- Shading (smooth vs flat facets) --------------------------------------

  /// Whether the current asset should render flat-shaded.
  bool _effectiveFlat(_PreparedModel p) {
    if (p.triangleCount > _flatMaxTris) return false;
    return switch (_shading) {
      'flat' => true,
      'smooth' => false,
      // Auto: small models without authored normals read better faceted.
      _ => !p.hadAuthoredNormals && p.triangleCount <= 1000,
    };
  }

  void _setShading(String shading) {
    if (shading == _shading) return;
    _shading = shading;
    _applyMode(_mode); // rebuild the asset with the new normals
  }

  /// De-indexes [p] into per-corner buffers with per-face normals.
  _FlatModel _buildFlatModel(_PreparedModel p) {
    final tris = p.indices.length ~/ 3;
    final n = tris * 3;
    final positions = Float32List(n * 3);
    final normals = Float32List(n * 3);
    final uvs = Float32List(n * 2);
    final colors = p.colors != null ? Float32List(n * 4) : null;
    for (var t = 0; t < tris; t++) {
      final a = p.indices[t * 3], b = p.indices[t * 3 + 1], c = p.indices[t * 3 + 2];
      // Face normal from the triangle's winding.
      final ax = p.positions[a * 3], ay = p.positions[a * 3 + 1], az = p.positions[a * 3 + 2];
      final bx = p.positions[b * 3], by = p.positions[b * 3 + 1], bz = p.positions[b * 3 + 2];
      final cx = p.positions[c * 3], cy = p.positions[c * 3 + 1], cz = p.positions[c * 3 + 2];
      final ux = bx - ax, uy = by - ay, uz = bz - az;
      final vx = cx - ax, vy = cy - ay, vz = cz - az;
      var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-12) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        nz = 1.0;
      }
      for (var k = 0; k < 3; k++) {
        final src = [a, b, c][k];
        final dst = t * 3 + k;
        positions[dst * 3] = p.positions[src * 3];
        positions[dst * 3 + 1] = p.positions[src * 3 + 1];
        positions[dst * 3 + 2] = p.positions[src * 3 + 2];
        normals[dst * 3] = nx;
        normals[dst * 3 + 1] = ny;
        normals[dst * 3 + 2] = nz;
        uvs[dst * 2] = p.uvs[src * 2];
        uvs[dst * 2 + 1] = p.uvs[src * 2 + 1];
        if (colors != null) {
          final pc = p.colors!;
          colors[dst * 4] = pc[src * 4];
          colors[dst * 4 + 1] = pc[src * 4 + 1];
          colors[dst * 4 + 2] = pc[src * 4 + 2];
          colors[dst * 4 + 3] = pc[src * 4 + 3];
        }
      }
    }
    final List<int> indices;
    final IndexType indexType;
    if (n <= 0x10000) {
      final i16 = Uint16List(n);
      for (var i = 0; i < n; i++) {
        i16[i] = i;
      }
      indices = i16;
      indexType = IndexType.USHORT;
    } else {
      final i32 = Uint32List(n);
      for (var i = 0; i < n; i++) {
        i32[i] = i;
      }
      indices = i32;
      indexType = IndexType.UINT;
    }
    return _FlatModel(positions, normals, uvs, colors, indices, indexType);
  }

  // --- Texture (parametric surface texture on any model) --------------------
  //
  // The encoded image (bundled asset or a glTF's embedded base-color texture)
  // is decoded NATIVELY on Filament's render thread (FilamentApp.decodeImage →
  // LinearImage) and uploaded via Texture.setLinearImage — the path thermion's
  // own test-suite exercises. The texture is bound to the ubershader's
  // baseColorMap (enabled by pointing baseColorIndex at UV set 0). Every step
  // is best-effort: any failure leaves the model rendering with its plain base
  // color — never black.

  Future<void> _setTextureAsset(String? assetPath) async {
    if (assetPath == null) {
      await _clearTexture();
      return;
    }
    try {
      final bytes = (await rootBundle.load(assetPath)).buffer.asUint8List();
      await _applyTextureBytes(bytes);
    } catch (_) {/* asset missing/undecodable — keep the current look */}
  }

  /// Swaps [encoded] (PNG/JPEG bytes) in as the active texture. Rebuilds the
  /// asset so the material is the hasBaseColorTexture VARIANT (the only one
  /// that owns the baseColorMap/baseColorIndex parameters — binding them on
  /// the plain variant is a native abort).
  Future<void> _applyTextureBytes(Uint8List encoded) async {
    final old = _texture;
    _texEncoded = encoded;
    _texture = null; // force a fresh GPU texture for the new pixels
    await _applyMode(_mode);
    // Destroy the previous texture only after the rebuild stopped sampling it.
    if (old != null) {
      try {
        await old.destroy();
      } catch (_) {}
    }
  }

  /// Removes the active texture: rebuilds the asset on the untextured material
  /// variant (base color drives the surface again), then frees the GPU texture.
  Future<void> _clearTexture() async {
    _texEncoded = null;
    final old = _texture;
    _texture = null;
    await _applyMode(_mode);
    if (old != null) {
      try {
        await old.destroy();
      } catch (_) {}
    }
  }

  /// Decodes [encoded] to 8-bit RGBA and uploads it into an sRGB8 texture.
  ///
  /// We deliberately AVOID Filament's float `LinearImage` + `RGBA32F` texture
  /// path. On real mobile GPUs (confirmed: Qualcomm Adreno 840, GLES 3.2) the
  /// 32-bit-float texture upload SEGFAULTS inside the vendor GL driver
  /// (`libGLESv2_adreno.so`) mid-upload — a native, uncatchable SIGSEGV while
  /// the driver reads the float source buffer (the alpha.33 device crash;
  /// the emulator never reproduced it because its software GL took a different
  /// path). 8-bit RGBA via `setImage` is the standard, universally-supported
  /// route. The image is decoded to straight RGBA8 on the Flutter side (no
  /// native float decode), then uploaded into an `SRGB8_A8` texture so the GPU
  /// linearises the base-color map correctly on sample.
  ///
  /// (`setImage`'s FFI passes the Dart enum `.index`, but `PixelDataFormat` and
  /// `PixelDataType` are declared in value order — `RGBA.index == 6 == value`,
  /// `UBYTE.index == 0 == value` — so the values reach native correctly.)
  Future<Texture?> _createGpuTexture(Uint8List encoded) async {
    final app = FilamentApp.instance!;
    Texture? tex;
    try {
      _trace('decodeImage');
      // Cap the decoded texture resolution (big-model GPU memory): a 4K base-color
      // texture is ~64 MB on the GPU (~85 with mips); decoding to ≤2K cuts it to
      // ~16 MB. Read the size via ImageDescriptor (no full decode), then decode
      // scaled — so a huge embedded texture never inflates GPU OR the decode buffer.
      const maxTexDim = 2048;
      final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ow = descriptor.width, oh = descriptor.height;
      final maxDim = ow > oh ? ow : oh;
      final ui.Codec codec;
      if (maxDim > maxTexDim && maxDim > 0) {
        final s = maxTexDim / maxDim;
        codec = await descriptor.instantiateCodec(
          targetWidth: (ow * s).round().clamp(1, maxTexDim),
          targetHeight: (oh * s).round().clamp(1, maxTexDim),
        );
      } else {
        codec = await descriptor.instantiateCodec();
      }
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;
      final w = uiImage.width;
      final h = uiImage.height;
      final bd = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      uiImage.dispose();
      // Dispose decode resources only AFTER the frame is fully decoded and its
      // pixels are copied out (toByteData makes its own copy). Disposing the
      // descriptor before getNextFrame() frees the encoded SkData while the
      // io.worker decode thread is still reading it → native use-after-free
      // (SIGSEGV null-deref in libflutter.so on io.worker). That was the
      // alpha.61 "5H crashes only sometimes" bug. Teardown in reverse order.
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (bd == null || w <= 0 || h <= 0) return null;
      final rgba = bd.buffer.asUint8List();
      _trace('createTexture');
      tex = await app.createTexture(
        w,
        h,
        // Both flags are required: SAMPLEABLE to bind it, UPLOADABLE so setImage
        // is allowed (createTexture defaults to {SAMPLEABLE} only).
        flags: const {
          TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
          TextureUsage.TEXTURE_USAGE_UPLOADABLE,
        },
        textureFormat: TextureFormat.SRGB8_A8,
      );
      _trace('setImage');
      await tex.setImage(
        0,
        rgba,
        w,
        h,
        PixelDataFormat.RGBA,
        PixelDataType.UBYTE,
      );
      return tex;
    } catch (_) {
      if (tex != null) {
        try {
          await tex.destroy();
        } catch (_) {}
      }
      return null;
    }
  }

  // --- Thumbnail (CPU rasterized, no GPU) -----------------------------------

  /// Encodes the CPU-rasterized RGBA thumbnail (built in the parse isolate) to a
  /// PNG on the UI isolate and hands it to the host to persist. One per load.
  Future<void> _maybeEmitThumbnail(_PreparedModel p) async {
    final cb = widget.onThumbnail;
    final rgba = p.thumbnailRgba;
    if (cb == null || rgba == null || _thumbCaptured) return;
    _thumbCaptured = true;
    final png = await _encodePng(rgba, p.thumbSize);
    if (png != null && mounted) cb(png);
  }

  /// RGBA8888 byte buffer (top-down, [size]×[size]) → PNG bytes. No flip — the
  /// software rasterizer already writes rows top-to-bottom.
  Future<Uint8List?> _encodePng(Uint8List rgba, int size) async {
    if (size <= 0 || rgba.length < size * size * 4) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final img = await completer.future;
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bytes?.buffer.asUint8List();
  }

  /// sRGB component → linear, so Filament's linear baseColorFactor shows the
  /// intended hue (passing raw sRGB washes the color out / shifts the hue).
  static double _srgbToLinear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    if (!_hasModel || viewer == null) {
      return ColoredBox(color: widget.background);
    }
    // LayoutBuilder gives us the live logical widget size, which the pivot
    // ray-cast (#8) needs to map a tapped point to NDC.
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastSize = constraints.biggest;
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          // Double-tap → set the orbit pivot to the model point under the
          // finger (#8). onDoubleTapDown carries the tap position; onScale*
          // keeps handling orbit/zoom/pan as before.
          onDoubleTapDown: (d) => _pickPivot(d.localPosition),
          // Render the Filament viewport at a reduced device-pixel-ratio (see
          // _kViewportRenderScale) so its HDR render targets — the dominant GPU
          // cost — shrink ~quadratically. The GestureDetector above works in
          // logical space, so orbit/zoom/pivot are unaffected.
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              devicePixelRatio: MediaQuery.of(context).devicePixelRatio *
                  _kViewportRenderScale,
            ),
            child: ThermionWidget(viewer: viewer),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Off-isolate parse + de-interleave (renderer-agnostic parser reused as-is)
// -----------------------------------------------------------------------------

class _ParseRequest {
  const _ParseRequest(
    this.path,
    this.format, {
    required this.thumbSize,
    required this.thumbAzimuth,
    required this.thumbElevation,
    required this.thumbBgColor,
    required this.thumbSurfaceColor,
  });
  final String path;
  final String format;
  final int thumbSize; // square thumbnail edge in px (0 disables)
  final double thumbAzimuth;
  final double thumbElevation;
  final int thumbBgColor; // 0xAARRGGBB
  final int thumbSurfaceColor; // 0xAARRGGBB (alpha ignored)
}

/// Parsed model, de-interleaved into Filament's separate attribute buffers.
class _PreparedModel {
  _PreparedModel({
    required this.positions,
    required this.normals,
    required this.uvs,
    this.colors,
    required this.indices,
    required this.indexType,
    required this.vertexCount,
    required this.triangleCount,
    required this.centerX,
    required this.centerY,
    required this.centerZ,
    required this.sizeY,
    required this.camDistance,
    required this.parseMs,
    this.thumbnailRgba,
    this.thumbSize = 0,
    this.baseColorArgb,
    this.textureBytes,
    this.hadAuthoredNormals = true,
  });

  /// Whether the file carried its own normals (false = parser smooth-computed
  /// them); drives the auto shading default (see _effectiveFlat).
  final bool hadAuthoredNormals;

  /// Model-supplied base colour (e.g. a glTF material) used as the initial color.
  final int? baseColorArgb;

  /// Model-supplied base-color texture (encoded PNG/JPEG, e.g. from a GLB),
  /// auto-applied on load so textured models show their real surface.
  final Uint8List? textureBytes;

  final Float32List positions; // 3 floats / vertex
  final Float32List normals; // 3 floats / vertex
  final Float32List uvs; // 2 floats / vertex

  /// Baked per-material vertex colors (4 floats / vertex, linear RGBA), only
  /// when the source glTF had ≥2 distinct material base colors — null for
  /// single-color models so they keep the plain factor-tinted path.
  final Float32List? colors;
  final List<int> indices; // triangle indices (Uint16List or Uint32List)
  final IndexType indexType;
  final int vertexCount;
  final int triangleCount;
  final double centerX, centerY, centerZ;

  /// AABB height (maxY − minY) in the file's units. Used to drop the ground
  /// shadow-catcher at the model's base in world space (see [groundPlaneWorldY]).
  final double sizeY;
  final double camDistance;
  final int parseMs;

  /// CPU-rasterized library thumbnail, RGBA8888, [thumbSize]²·4 bytes (top-down),
  /// or null if rasterization was skipped/failed. Encoded to PNG on the UI thread.
  final Uint8List? thumbnailRgba;
  final int thumbSize;
}

/// Isolate entry: read + parse, then split the interleaved buffer into the
/// separate position/normal/uv buffers Filament's geometry builder expects.
/// Triangle budget for on-device decimation (big-model memory). A mesh over this
/// is grid-cluster collapsed in the parse isolate so its geometry can't pin
/// hundreds of MB of Float32Lists in the Dart heap — a 1.3M-tri model held
/// ~316 MB in the "Unknown"/Dart bucket, the dominant cost when a big model is
/// open. Source-agnostic: bounds RAW big GLBs too, not just server-converted
/// .blends. Tunable; ~350k keeps a heavy model's geometry to ~tens of MB.
const int _kMaxTriangles = 350000;

/// Reduced mesh from [_decimateMesh].
class _DecimatedMesh {
  _DecimatedMesh(this.positions, this.normals, this.uvs, this.colors,
      this.indices, this.vertexCount, this.triangleCount);
  final Float32List positions;
  final Float32List normals;
  final Float32List uvs;
  final Float32List? colors; // 4/vertex linear RGBA, null when source had none
  final List<int> indices;
  final int vertexCount;
  final int triangleCount;
}

/// Grid vertex-clustering decimation: snaps every vertex into a uniform grid over
/// the model AABB, collapses each occupied cell to one AVERAGED vertex, and
/// rebuilds the triangle list (a triangle whose 3 corners don't land in 3 distinct
/// cells is degenerate and dropped). O(n), no deps, runs in the parse isolate. The
/// output is bounded by the occupied-cell count, so memory is capped regardless of
/// the source mesh size. Not QEM-quality, but it preserves the silhouette and —
/// the point here — never lets the Dart heap hold more than the budget. The grid
/// is sized so a surface (~R² occupied cells) lands near [targetTriangles].
_DecimatedMesh _decimateMesh(
  Float32List positions,
  Float32List normals,
  Float32List uvs,
  Float32List? colors,
  List<int> indices,
  int triangleCount,
  double minX,
  double minY,
  double minZ,
  double sizeX,
  double sizeY,
  double sizeZ,
  int targetTriangles,
) {
  var grid = math.sqrt(targetTriangles / 2).ceil();
  if (grid < 8) grid = 8;
  if (grid > 1024) grid = 1024;
  final gR = grid.toDouble();
  final ex = sizeX > 1e-9 ? sizeX : 1e-9;
  final ey = sizeY > 1e-9 ? sizeY : 1e-9;
  final ez = sizeZ > 1e-9 ? sizeZ : 1e-9;
  final n = positions.length ~/ 3;

  final cellToNew = <int, int>{}; // grid cell key → new vertex index
  final oldToNew = Int32List(n);
  final sumPx = <double>[], sumPy = <double>[], sumPz = <double>[];
  final sumNx = <double>[], sumNy = <double>[], sumNz = <double>[];
  final sumU = <double>[], sumV = <double>[];
  // Baked vertex colors averaged like the other attributes (a cell straddling
  // a material boundary blends its parts' colors — acceptable at this scale).
  final sumR = <double>[], sumG = <double>[], sumB = <double>[], sumA = <double>[];
  final count = <int>[];

  for (var i = 0; i < n; i++) {
    var gx = (((positions[i * 3] - minX) / ex) * gR).floor();
    var gy = (((positions[i * 3 + 1] - minY) / ey) * gR).floor();
    var gz = (((positions[i * 3 + 2] - minZ) / ez) * gR).floor();
    if (gx < 0) {
      gx = 0;
    } else if (gx >= grid) {
      gx = grid - 1;
    }
    if (gy < 0) {
      gy = 0;
    } else if (gy >= grid) {
      gy = grid - 1;
    }
    if (gz < 0) {
      gz = 0;
    } else if (gz >= grid) {
      gz = grid - 1;
    }
    final key = gx + gy * grid + gz * grid * grid;
    var ni = cellToNew[key];
    if (ni == null) {
      ni = count.length;
      cellToNew[key] = ni;
      sumPx.add(0);
      sumPy.add(0);
      sumPz.add(0);
      sumNx.add(0);
      sumNy.add(0);
      sumNz.add(0);
      sumU.add(0);
      sumV.add(0);
      if (colors != null) {
        sumR.add(0);
        sumG.add(0);
        sumB.add(0);
        sumA.add(0);
      }
      count.add(0);
    }
    oldToNew[i] = ni;
    sumPx[ni] += positions[i * 3];
    sumPy[ni] += positions[i * 3 + 1];
    sumPz[ni] += positions[i * 3 + 2];
    sumNx[ni] += normals[i * 3];
    sumNy[ni] += normals[i * 3 + 1];
    sumNz[ni] += normals[i * 3 + 2];
    sumU[ni] += uvs[i * 2];
    sumV[ni] += uvs[i * 2 + 1];
    if (colors != null) {
      sumR[ni] += colors[i * 4];
      sumG[ni] += colors[i * 4 + 1];
      sumB[ni] += colors[i * 4 + 2];
      sumA[ni] += colors[i * 4 + 3];
    }
    count[ni]++;
  }

  final nv = count.length;
  final newPos = Float32List(nv * 3);
  final newNrm = Float32List(nv * 3);
  final newUv = Float32List(nv * 2);
  final newCol = colors != null ? Float32List(nv * 4) : null;
  for (var j = 0; j < nv; j++) {
    final c = count[j].toDouble();
    newPos[j * 3] = sumPx[j] / c;
    newPos[j * 3 + 1] = sumPy[j] / c;
    newPos[j * 3 + 2] = sumPz[j] / c;
    var nx = sumNx[j], ny = sumNy[j], nz = sumNz[j];
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl > 1e-9) {
      nx /= nl;
      ny /= nl;
      nz /= nl;
    }
    newNrm[j * 3] = nx;
    newNrm[j * 3 + 1] = ny;
    newNrm[j * 3 + 2] = nz;
    newUv[j * 2] = sumU[j] / c;
    newUv[j * 2 + 1] = sumV[j] / c;
    if (newCol != null) {
      newCol[j * 4] = sumR[j] / c;
      newCol[j * 4 + 1] = sumG[j] / c;
      newCol[j * 4 + 2] = sumB[j] / c;
      newCol[j * 4 + 3] = sumA[j] / c;
    }
  }

  final tris = math.min(triangleCount, indices.length ~/ 3);
  final newIdx = <int>[];
  for (var t = 0; t < tris; t++) {
    final a = oldToNew[indices[t * 3]];
    final b = oldToNew[indices[t * 3 + 1]];
    final c = oldToNew[indices[t * 3 + 2]];
    if (a != b && b != c && a != c) {
      newIdx
        ..add(a)
        ..add(b)
        ..add(c);
    }
  }
  final List<int> idx =
      nv <= 0x10000 ? Uint16List.fromList(newIdx) : Uint32List.fromList(newIdx);
  return _DecimatedMesh(
      newPos, newNrm, newUv, newCol, idx, nv, newIdx.length ~/ 3);
}

_PreparedModel _prepareModelEntry(_ParseRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final sw = Stopwatch()..start();
  final mesh = ModelParser.parse(bytes, format: req.format);
  final n = mesh.vertexCount;
  final src = mesh.vertices; // interleaved [px,py,pz,nx,ny,nz,u,v,r,g,b,a]
  final positions = Float32List(n * 3);
  final normals = Float32List(n * 3);
  final uvs = Float32List(n * 2);
  // Baked per-material vertex colors (glTF multi-material) ride along only
  // when the parser flagged them — single-color models skip the buffer.
  final colors = mesh.hasVertexColors ? Float32List(n * 4) : null;
  for (var i = 0; i < n; i++) {
    final s = i * kFloatsPerVertex;
    positions[i * 3] = src[s];
    positions[i * 3 + 1] = src[s + 1];
    positions[i * 3 + 2] = src[s + 2];
    normals[i * 3] = src[s + 3];
    normals[i * 3 + 1] = src[s + 4];
    normals[i * 3 + 2] = src[s + 5];
    uvs[i * 2] = src[s + 6];
    uvs[i * 2 + 1] = src[s + 7];
    if (colors != null) {
      colors[i * 4] = src[s + 8];
      colors[i * 4 + 1] = src[s + 9];
      colors[i * 4 + 2] = src[s + 10];
      colors[i * 4 + 3] = src[s + 11];
    }
  }

  // Models without authored UVs (STL/OFF/3MF, OBJ without vt, glTF without
  // TEXCOORD_0) get box-mapped fallback UVs so a texture still wraps sensibly:
  // each vertex projects onto the bounds plane perpendicular to its normal's
  // dominant axis, scaled so the texture tiles ~2× across the model.
  var hasUv = false;
  for (var i = 0; i < uvs.length; i++) {
    if (uvs[i] != 0) {
      hasUv = true;
      break;
    }
  }
  final mb = mesh.bounds;
  if (!hasUv && n > 0) {
    final ext = math.max(mb.longestExtent, 1e-6);
    const tiles = 2.0;
    for (var i = 0; i < n; i++) {
      final ax = normals[i * 3].abs();
      final ay = normals[i * 3 + 1].abs();
      final az = normals[i * 3 + 2].abs();
      final px = positions[i * 3], py = positions[i * 3 + 1], pz = positions[i * 3 + 2];
      double u, v;
      if (ax >= ay && ax >= az) {
        u = (pz - mb.minZ) / ext;
        v = (py - mb.minY) / ext;
      } else if (ay >= ax && ay >= az) {
        u = (px - mb.minX) / ext;
        v = (pz - mb.minZ) / ext;
      } else {
        u = (px - mb.minX) / ext;
        v = (py - mb.minY) / ext;
      }
      uvs[i * 2] = u * tiles;
      uvs[i * 2 + 1] = v * tiles;
    }
  }

  // Index buffer: reuse OBJ's indices, or synthesize sequential ones for STL
  // (which is inherently non-indexed). Pick the narrowest index type that fits.
  final List<int> indices;
  final IndexType indexType;
  if (mesh.indices16 != null) {
    indices = mesh.indices16!;
    indexType = IndexType.USHORT;
  } else if (mesh.indices32 != null) {
    indices = mesh.indices32!;
    indexType = IndexType.UINT;
  } else if (n <= 0x10000) {
    indices = Uint16List(n);
    for (var i = 0; i < n; i++) {
      indices[i] = i;
    }
    indexType = IndexType.USHORT;
  } else {
    indices = Uint32List(n);
    for (var i = 0; i < n; i++) {
      indices[i] = i;
    }
    indexType = IndexType.UINT;
  }

  sw.stop();

  final b = mesh.bounds;
  final radius = 0.5 *
      math.sqrt(b.sizeX * b.sizeX + b.sizeY * b.sizeY + b.sizeZ * b.sizeZ);
  final camDistance = radius <= 0 ? 5.0 : radius * 3.0;

  // On-device decimation (big-model memory): collapse an over-budget mesh right
  // here in the parse isolate so its geometry can't pin hundreds of MB of Dart
  // Float32Lists once it's open. Source-agnostic — bounds a RAW big GLB too, not
  // just server-converted .blends. Everything downstream (thumbnail + the returned
  // model) uses the reduced arrays; the originals become unreferenced and GC.
  var dPositions = positions;
  var dNormals = normals;
  var dUvs = uvs;
  var dColors = colors;
  var dIndices = indices;
  var dIndexType = indexType;
  var dVertexCount = n;
  var dTriCount = mesh.triangleCount;
  if (mesh.triangleCount > _kMaxTriangles) {
    final dec = _decimateMesh(positions, normals, uvs, colors, indices,
        mesh.triangleCount, b.minX, b.minY, b.minZ, b.sizeX, b.sizeY, b.sizeZ,
        _kMaxTriangles);
    dPositions = dec.positions;
    dNormals = dec.normals;
    dUvs = dec.uvs;
    dColors = dec.colors;
    dIndices = dec.indices;
    dVertexCount = dec.vertexCount;
    dTriCount = dec.triangleCount;
    dIndexType = dVertexCount <= 0x10000 ? IndexType.USHORT : IndexType.UINT;
  }

  // Rasterize the library thumbnail here in the parse isolate (CPU only — never
  // touches Filament's GPU render thread, which is why Thermion's capture()
  // crashed on device). Only the small RGBA buffer crosses back to the UI thread.
  Uint8List? thumb;
  if (req.thumbSize > 0) {
    thumb = rasterizeThumbnail(
      positions: dPositions,
      indices: dIndices,
      triangleCount: dTriCount,
      centerX: b.centerX,
      centerY: b.centerY,
      centerZ: b.centerZ,
      minX: b.minX,
      minY: b.minY,
      minZ: b.minZ,
      maxX: b.maxX,
      maxY: b.maxY,
      maxZ: b.maxZ,
      azimuth: req.thumbAzimuth,
      elevation: req.thumbElevation,
      size: req.thumbSize,
      bgColor: req.thumbBgColor,
      surfaceColor: req.thumbSurfaceColor,
    );
  }

  return _PreparedModel(
    positions: dPositions,
    normals: dNormals,
    uvs: dUvs,
    colors: dColors,
    indices: dIndices,
    indexType: dIndexType,
    vertexCount: dVertexCount,
    triangleCount: dTriCount,
    centerX: b.centerX,
    centerY: b.centerY,
    centerZ: b.centerZ,
    sizeY: b.sizeY,
    camDistance: camDistance,
    parseMs: sw.elapsedMilliseconds,
    thumbnailRgba: thumb,
    thumbSize: req.thumbSize,
    baseColorArgb: mesh.baseColorArgb,
    textureBytes: mesh.textureBytes,
    hadAuthoredNormals: mesh.hadAuthoredNormals,
  );
}
