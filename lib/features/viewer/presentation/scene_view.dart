import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
// Hide Flutter's View/Texture so Thermion's same-named types resolve without a
// name clash (we don't use Flutter's View/Texture widgets in this file).
import 'package:flutter/widgets.dart' hide View, Texture;
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
  });

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

  // --- Texture state (decoded RGBA, uploaded lazily into a Filament texture).
  // The decoded pixels are retained so render-mode rebuilds (new material) can
  // re-apply the texture without re-decoding. All GPU texture work is
  // best-effort: a failure leaves the model on its plain base color.
  Uint8List? _texRgba;
  int _texWidth = 0, _texHeight = 0;
  Texture? _texture; // current Filament texture (one at a time)
  TextureSampler? _texSampler; // shared REPEAT/LINEAR sampler, created once
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
      _thumbCaptured = false;
      // Show the model in its own colour if it carries one (e.g. a glTF
      // material). The user can still re-pick from the Render panel.
      if (prepared.baseColorArgb != null) {
        _baseColor = Color(prepared.baseColorArgb!);
      }
      // Texture state belongs to one model: drop the previous model's texture
      // (destroyed after the rebuild below replaces the material that samples
      // it), and pre-decode this model's own embedded texture if it has one
      // (e.g. a textured GLB) so the rebuild binds it.
      final staleTex = _texture;
      _texture = null;
      _texRgba = null;
      _texWidth = 0;
      _texHeight = 0;
      if (prepared.textureBytes != null) {
        await _decodeTexture(prepared.textureBytes!);
      }
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
      } else {
        geometry = Geometry(
          p.positions,
          p.indices,
          normals: p.normals,
          uvs: p.uvs,
          indexType: p.indexType,
        );
      }

      // Material: lit ubershader for solid, blended for x-ray, unlit for the
      // wireframe (line shading is meaningless).
      final material = await FilamentApp.instance!.createUbershaderMaterialInstance(
        unlit: wireframe,
        alphaMode: xray ? AlphaMode.BLEND : AlphaMode.OPAQUE,
        // Double-sided so back faces are lit with flipped normals — otherwise
        // the inside/under faces (OBJ/STL winding is inconsistent) stay black
        // and the color doesn't read on every surface.
        doubleSided: true,
      );
      await material.setCullingMode(CullingMode.NONE);
      if (xray) await material.setTransparencyMode(TransparencyMode.DEFAULT);
      await _applyColorTo(material);
      // Re-bind the active texture to the fresh material (solid/x-ray only —
      // wireframe lines have no meaningful surface to texture).
      if (!wireframe && _texRgba != null) await _applyTextureTo(material);

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
    final textured = _texRgba != null && _mode != 'wireframe';
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
    if (_texRgba != null) {
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

  // --- Texture (parametric surface texture on any model) --------------------
  //
  // The encoded image (bundled asset or a glTF's embedded base-color texture)
  // is decoded to RGBA on the UI isolate, uploaded into a Filament sRGB
  // texture and bound to the ubershader's baseColorMap (enabled by pointing
  // baseColorIndex at UV set 0). Every step is best-effort: any failure leaves
  // the model rendering with its plain base color — never black, never a crash.

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

  /// Decodes [encoded] (PNG/JPEG) and swaps it in as the active texture.
  Future<void> _applyTextureBytes(Uint8List encoded) async {
    final old = _texture;
    if (!await _decodeTexture(encoded)) return;
    _texture = null; // force a fresh GPU texture for the new pixels
    final mi = _material;
    if (mi != null) await _applyTextureTo(mi);
    // Destroy the previous texture only after the new one is bound.
    if (old != null) {
      try {
        await old.destroy();
      } catch (_) {}
    }
  }

  /// Removes the active texture: disables baseColorMap sampling on the live
  /// material (baseColorIndex = -1), restores the base color, then frees the
  /// GPU texture.
  Future<void> _clearTexture() async {
    _texRgba = null;
    _texWidth = 0;
    _texHeight = 0;
    final mi = _material;
    final old = _texture;
    _texture = null;
    try {
      if (mi != null) {
        await UbershaderMaterialInstance(mi).setBaseColorUV(-1);
        await _applyColorTo(mi);
      }
    } catch (_) {/* worst case: texture lingers until the next mode rebuild */}
    if (old != null) {
      try {
        await old.destroy();
      } catch (_) {}
    }
  }

  /// Decodes PNG/JPEG bytes into [_texRgba] (straight RGBA8888).
  Future<bool> _decodeTexture(Uint8List encoded) async {
    try {
      final codec = await ui.instantiateImageCodec(encoded);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data =
          await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      final w = img.width, h = img.height;
      img.dispose();
      codec.dispose();
      if (data == null || w <= 0 || h <= 0) return false;
      _texRgba = data.buffer.asUint8List();
      _texWidth = w;
      _texHeight = h;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Binds the decoded texture to [mi], creating the GPU texture on demand.
  Future<void> _applyTextureTo(MaterialInstance mi) async {
    final rgba = _texRgba;
    final app = FilamentApp.instance;
    if (rgba == null || app == null) return;
    try {
      var tex = _texture;
      tex ??= _texture = await _createGpuTexture(rgba, _texWidth, _texHeight);
      if (tex == null) return;
      _texSampler ??= await app.createTextureSampler(
        minFilter: TextureMinFilter.LINEAR_MIPMAP_LINEAR,
        magFilter: TextureMagFilter.LINEAR,
        wrapS: TextureWrapMode.REPEAT,
        wrapT: TextureWrapMode.REPEAT,
      );
      final uber = UbershaderMaterialInstance(mi);
      await uber.setBaseColorTexture(tex, _texSampler!);
      await uber.setBaseColorUV(0); // enable: sample baseColorMap with UV set 0
      await _applyColorTo(mi); // white factor while textured (texture shows true)
    } catch (_) {/* model stays plain-colored */}
  }

  /// Uploads RGBA pixels into a new sRGB Filament texture — mipmapped when the
  /// device allows the blit-capable allocation, single-level otherwise.
  Future<Texture?> _createGpuTexture(Uint8List rgba, int w, int h) async {
    final app = FilamentApp.instance!;
    var levels = 1;
    var maxDim = math.max(w, h);
    while (maxDim > 1) {
      levels++;
      maxDim >>= 1;
    }
    try {
      final tex = await app.createTexture(
        w,
        h,
        levels: levels,
        flags: {
          TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
          TextureUsage.TEXTURE_USAGE_UPLOADABLE,
          TextureUsage.TEXTURE_USAGE_BLIT_SRC,
          TextureUsage.TEXTURE_USAGE_BLIT_DST,
        },
        textureFormat: TextureFormat.SRGB8_A8,
      );
      try {
        await tex.setImage(
            0, rgba, w, h, PixelDataFormat.RGBA, PixelDataType.UBYTE);
        await tex.generateMipmaps();
        return tex;
      } catch (_) {
        try {
          await tex.destroy();
        } catch (_) {}
        rethrow;
      }
    } catch (_) {/* fall through to the single-level path */}
    try {
      final tex = await app.createTexture(
        w,
        h,
        textureFormat: TextureFormat.SRGB8_A8,
      );
      await tex.setImage(
          0, rgba, w, h, PixelDataFormat.RGBA, PixelDataType.UBYTE);
      return tex;
    } catch (_) {
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
  });

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
  );
}
