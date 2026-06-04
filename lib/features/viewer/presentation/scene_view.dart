import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
      // No IBL/skybox is bundled, so lighting is entirely direct. A single sun
      // leaves the far side pure black; a key + fill + rim trio approximates
      // ambient so the whole model reads.
      await viewer.addDirectLight(DirectLight.sun(
        direction: Vector3(0.3, -0.8, 0.5)..normalize(),
        intensity: 70000,
        castShadows: false,
      ));
      await viewer.addDirectLight(DirectLight.sun(
        direction: Vector3(-0.6, -0.2, -0.5)..normalize(),
        intensity: 38000,
        castShadows: false,
      ));
      await viewer.addDirectLight(DirectLight.sun(
        direction: Vector3(0.1, 0.9, -0.3)..normalize(),
        intensity: 22000,
        castShadows: false,
      ));
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
      if (_viewerReady) await _applyMode(_mode, frame: true);
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
  Future<void> _applyColorTo(MaterialInstance mi) async {
    await mi.setParameterFloat4(
      'baseColorFactor',
      _srgbToLinear(_baseColor.r),
      _srgbToLinear(_baseColor.g),
      _srgbToLinear(_baseColor.b),
      _currentAlpha,
    );
  }

  Future<void> _setColor(Color color) async {
    _baseColor = color;
    final mi = _material;
    if (mi != null) await _applyColorTo(mi);
  }

  void _setRenderMode(String mode) {
    _applyMode(mode);
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
  });

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
  );
}
