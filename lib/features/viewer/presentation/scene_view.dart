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

import '../data/model_parser.dart';
import '../data/thumbnail_raster.dart';

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

  /// Sets the model's base color (the surface tint the light shades).
  void setColor(Color color) => _state?._setColor(color);

  /// Light-rig intensity multiplier (0.2–2.5; 1.0 = default brightness).
  void setLightIntensity(double factor) =>
      _state?._setLightIntensity(factor);

  /// Rotates the whole light rig around Y by [azimuthRad] (relight angle).
  void setLightAngle(double azimuthRad) => _state?._setLightAzimuth(azimuthRad);

  /// Environment (image-based) lighting amount 0..1 (0 = off; reflections +
  /// soft ambient as it rises).
  void setEnvironment(double amount) => _state?._setEnvironment(amount);

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
  _FlatModel(this.positions, this.normals, this.uvs, this.indices, this.indexType);
  final Float32List positions;
  final Float32List normals;
  final Float32List uvs;
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
  double _currentAlpha = 1.0; // 0.35 in x-ray

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
  bool _iblLoaded = false; // image-based-lighting environment currently active
  bool _rebuilding = false;
  String? _pendingMode; // latest mode requested while a rebuild was in flight

  // --- Orbit state: spherical camera around the (panned) model center. ---
  double _azimuth = _isoAzimuth;
  double _elevation = _isoElevation;
  double _radius = 5;
  double _minRadius = 0.5;
  double _maxRadius = 50;
  double _startRadius = 5;

  /// Camera pivot, shifted by two-finger pan so the model can be moved up out
  /// from behind the bottom panel (or recentered). Origin = model center.
  final Vector3 _target = Vector3.zero();

  bool _applyingCamera = false;
  bool _cameraDirty = false;

  static const double _isoAzimuth = math.pi / 4;
  static const double _isoElevation = 0.6;
  static const double _elevationLimit = math.pi / 2 - 0.05;
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
      await viewer.setBackgroundColor(
        widget.background.r,
        widget.background.g,
        widget.background.b,
        1.0,
      );
      // No IBL/skybox is bundled, so lighting is entirely direct. With only a
      // key + fill + rim trio, a low-poly model (e.g. the 8-face octahedron) can
      // still have facets that face away from every light → pure black. Surround
      // the model with six suns (the key/fill/rim plus three dim counter-lights
      // roughly opposite them) so every facet picks up some light — a poor-man's
      // ambient that kills the half-black look without an IBL.
      _lights.clear();
      for (final (x, y, z, inten) in _kLightRig) {
        final e = await viewer.addDirectLight(DirectLight.sun(
          direction: _rotatedDir(x, y, z, _lightAzimuth),
          intensity: inten * _lightIntensity,
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
      // baseline. The user opts in + dials it via the Render panel's Environment
      // slider (see _setEnvironment), which loads/removes the IBL on demand.
      final camera = await viewer.getActiveCamera();
      if (!mounted) {
        await viewer.dispose();
        return;
      }
      _viewer = viewer;
      _camera = camera;
      _viewerReady = true;
      if (_model != null) await _applyMode(_mode, frame: true);
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
          thumbAzimuth: _isoAzimuth,
          thumbElevation: _isoElevation,
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

  /// Builds (or rebuilds) the on-screen asset for [mode], optionally framing the
  /// camera to it (on first load / model change). Coalesces rapid mode taps.
  Future<void> _applyMode(String mode, {bool frame = false}) async {
    final viewer = _viewer;
    final p = _model;
    if (viewer == null || p == null) return;
    if (_rebuilding) {
      _pendingMode = mode; // apply once the in-flight rebuild finishes
      return;
    }
    _rebuilding = true;
    try {
      _mode = mode;
      if (frame) widget.onStatus(const ModelSceneStatus(loading: true));

      final old = _asset;
      if (old != null) {
        await viewer.destroyAsset(old);
        _asset = null;
        _material = null;
      }

      final bool wireframe = mode == 'wireframe';
      final bool xray = mode == 'xray';
      _currentAlpha = xray ? _xrayAlpha : 1.0;

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
          indexType: flat.indexType,
        );
      } else {
        geometry = Geometry(
          p.positions,
          p.indices,
          normals: p.normals,
          uvs: p.uvs,
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
        releaseSourceData: false, // keep buffers for other render modes
      );
      _asset = asset;
      _material = material;

      await FilamentApp.instance!.setTransform(
        asset.entity,
        Matrix4.translation(Vector3(-p.centerX, -p.centerY, -p.centerZ)),
      );
      await viewer.addToScene(asset);

      if (frame) {
        final modelRadius = p.camDistance / 3.0;
        _radius = p.camDistance;
        _startRadius = _radius;
        _minRadius = math.max(modelRadius * 0.4, 0.05);
        _maxRadius = p.camDistance * 5.0;
        _azimuth = _isoAzimuth;
        _elevation = _isoElevation;
        _target.setZero();
        await _applyCameraNow();
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
      if (next != null && next != _mode) {
        _pendingMode = null;
        await _applyMode(next);
      } else {
        _pendingMode = null;
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

  /// Writes the current base color (sRGB → linear) into [mi] at the mode alpha.
  /// While a texture is active (and shown — not in wireframe) the factor is
  /// white so the texture's own colors come through unmultiplied.
  Future<void> _applyColorTo(MaterialInstance mi) async {
    final textured = _texture != null && _mode != 'wireframe';
    await mi.setParameterFloat4(
      'baseColorFactor',
      textured ? 1.0 : _srgbToLinear(_baseColor.r),
      textured ? 1.0 : _srgbToLinear(_baseColor.g),
      textured ? 1.0 : _srgbToLinear(_baseColor.b),
      _currentAlpha,
    );
  }

  Future<void> _setColor(Color color) async {
    _baseColor = color;
    // Picking a color switches the surface back to flat color (texture off) —
    // baseColorFactor and baseColorMap are mutually exclusive in the UI.
    if (_texEncoded != null) {
      await _clearTexture();
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

  /// Environment (image-based) lighting amount, 0..1. 0 removes the IBL (the
  /// directional rig + filmic baseline); >0 loads the bundled studio IBL at a
  /// proportional intensity for reflections + soft ambient. Best-effort. Call on
  /// release — (re)loading the KTX isn't free.
  Future<void> _setEnvironment(double amount) async {
    final v = _viewer;
    if (v == null) return;
    final a = amount.clamp(0.0, 1.0);
    try {
      if (a <= 0.01) {
        if (_iblLoaded) {
          await v.removeIbl();
          _iblLoaded = false;
        }
      } else {
        // loadIbl replaces any existing IBL (destroyExisting); thermion resolves
        // asset:// via rootBundle. Map 0..1 → a gentle 0..36000 intensity.
        await v.loadIbl('asset://assets/env/studio_ibl.ktx',
            intensity: a * 36000);
        _iblLoaded = true;
      }
    } catch (_) {/* keep the directional rig as the only light */}
  }

  /// Re-aims every light for a new rig azimuth (cheap — direction only, no
  /// re-creation). Live as the angle slider drags.
  Future<void> _setLightAzimuth(double az) async {
    _lightAzimuth = az;
    final v = _viewer;
    if (v == null) return;
    for (var i = 0; i < _lights.length && i < _kLightRig.length; i++) {
      final (x, y, z, _) = _kLightRig[i];
      await v.setLightDirection(_lights[i], _rotatedDir(x, y, z, az));
    }
  }

  /// Re-creates the rig at a new intensity multiplier (Thermion has no runtime
  /// intensity setter, so remove + re-add — lights are cheap). Call on release.
  Future<void> _setLightIntensity(double factor) async {
    _lightIntensity = factor.clamp(0.2, 2.5);
    final v = _viewer;
    if (v == null) return;
    for (final e in _lights) {
      await v.removeLight(e);
    }
    _lights.clear();
    for (final (x, y, z, inten) in _kLightRig) {
      final e = await v.addDirectLight(DirectLight.sun(
        direction: _rotatedDir(x, y, z, _lightAzimuth),
        intensity: inten * _lightIntensity,
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
    return _FlatModel(positions, normals, uvs, indices, indexType);
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

  /// Decodes [encoded] natively and uploads it into an RGBA32F linear texture.
  ///
  /// `requireAlpha: true` is LOAD-BEARING: it forces the native stb decode to
  /// 4 channels. A 3-channel image (any JPEG, alpha-less PNG — e.g. the
  /// bundled wood/metal/marble/fabric and ToyCar's livery) would otherwise
  /// take the RGB/RGB32F path, which thermion's own tests never exercise and
  /// which Filament ABORTS on natively at `setImage` (the alpha.28–.31 device
  /// crash; pinned `TTexture.cpp Texture_loadImage` sizes the buffer from the
  /// channel count and Vulkan rejects 3-channel float). The 4-channel path
  /// (RGBA32F + RGBA + FLOAT) is exactly what thermion's test-suite uses.
  Future<Texture?> _createGpuTexture(Uint8List encoded) async {
    final app = FilamentApp.instance!;
    LinearImage? image;
    try {
      _trace('decodeImage');
      image = await app.decodeImage(encoded, requireAlpha: true);
      _trace('getImageDimensions');
      final w = await image.getWidth();
      final h = await image.getHeight();
      final channels = await image.getChannels();
      // Anything but the upstream-tested 4-channel layout is a no-go.
      if (w <= 0 || h <= 0 || channels != 4) return null;
      _trace('createTexture');
      final tex = await app.createTexture(
        w,
        h,
        textureFormat: TextureFormat.RGBA32F,
      );
      try {
        _trace('setLinearImage');
        await tex.setLinearImage(
          image,
          PixelDataFormat.RGBA,
          PixelDataType.FLOAT,
        );
        return tex;
      } catch (_) {
        try {
          await tex.destroy();
        } catch (_) {}
        return null;
      }
    } catch (_) {
      return null;
    } finally {
      try {
        _trace('destroyLinearImage');
        await image?.destroy();
      } catch (_) {}
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
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: ThermionWidget(viewer: viewer),
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
    required this.indices,
    required this.indexType,
    required this.vertexCount,
    required this.triangleCount,
    required this.centerX,
    required this.centerY,
    required this.centerZ,
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
  final List<int> indices; // triangle indices (Uint16List or Uint32List)
  final IndexType indexType;
  final int vertexCount;
  final int triangleCount;
  final double centerX, centerY, centerZ;
  final double camDistance;
  final int parseMs;

  /// CPU-rasterized library thumbnail, RGBA8888, [thumbSize]²·4 bytes (top-down),
  /// or null if rasterization was skipped/failed. Encoded to PNG on the UI thread.
  final Uint8List? thumbnailRgba;
  final int thumbSize;
}

/// Isolate entry: read + parse, then split the interleaved buffer into the
/// separate position/normal/uv buffers Filament's geometry builder expects.
_PreparedModel _prepareModelEntry(_ParseRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final sw = Stopwatch()..start();
  final mesh = ModelParser.parse(bytes, format: req.format);
  final n = mesh.vertexCount;
  final src = mesh.vertices; // interleaved [px,py,pz,nx,ny,nz,u,v,r,g,b,a]
  final positions = Float32List(n * 3);
  final normals = Float32List(n * 3);
  final uvs = Float32List(n * 2);
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

  // Rasterize the library thumbnail here in the parse isolate (CPU only — never
  // touches Filament's GPU render thread, which is why Thermion's capture()
  // crashed on device). Only the small RGBA buffer crosses back to the UI thread.
  Uint8List? thumb;
  if (req.thumbSize > 0) {
    thumb = rasterizeThumbnail(
      positions: positions,
      indices: indices,
      triangleCount: mesh.triangleCount,
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
    positions: positions,
    normals: normals,
    uvs: uvs,
    indices: indices,
    indexType: indexType,
    vertexCount: n,
    triangleCount: mesh.triangleCount,
    centerX: b.centerX,
    centerY: b.centerY,
    centerZ: b.centerZ,
    camDistance: camDistance,
    parseMs: sw.elapsedMilliseconds,
    thumbnailRgba: thumb,
    thumbSize: req.thumbSize,
    baseColorArgb: mesh.baseColorArgb,
    textureBytes: mesh.textureBytes,
    hadAuthoredNormals: mesh.hadAuthoredNormals,
  );
}
