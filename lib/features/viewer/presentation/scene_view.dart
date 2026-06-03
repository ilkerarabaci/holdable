import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
// Thermion re-exports thermion_dart (ThermionFlutterPlugin, ThermionViewer,
// Geometry, FilamentApp, DirectLight, Camera, the material/culling/index enums),
// vector_math_64 (Vector3, Matrix4) and dart:typed_data. Hide the names that
// collide with flutter/widgets.
import 'package:thermion_flutter/thermion_flutter.dart' hide Texture, View, Material;

import '../data/model_parser.dart';

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
/// handler — that handler felt stiff and couldn't zoom in past the framing
/// distance. This restores the free, responsive feel of the v0.2 viewer.
///
/// Keeps the same widget contract as the prior renderer lines so the host
/// [ViewerScreen] is unchanged. Solid shading + orbit + presets + color; render
/// modes (wireframe / x-ray) and thumbnail capture follow.
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

class _ModelSceneViewState extends State<ModelSceneView> {
  ThermionViewer? _viewer;
  Camera? _camera;
  ThermionAsset? _asset;
  MaterialInstance? _material;

  /// Just-parsed model awaiting GPU upload (set on parse, nulled after upload).
  _PreparedModel? _pending;

  bool _viewerReady = false;
  bool _hasModel = false; // a geometry is on screen

  // --- Orbit state: spherical camera around the (origin-centered) model. ---
  double _azimuth = _isoAzimuth;
  double _elevation = _isoElevation;
  double _radius = 5;
  double _minRadius = 0.5;
  double _maxRadius = 50;
  double _startRadius = 5; // captured on gesture start for pinch-zoom

  // Coalesce camera writes: lookAt is async FFI, so we never let updates queue
  // unbounded — apply the latest pose, re-apply only if it changed meanwhile.
  bool _applyingCamera = false;
  bool _cameraDirty = false;

  static const double _isoAzimuth = math.pi / 4;
  static const double _isoElevation = 0.6; // ~34° above the horizon
  static const double _elevationLimit = math.pi / 2 - 0.05;

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
    viewer?.dispose(); // fire-and-forget; unloads scene, leaves engine intact
    super.dispose();
  }

  /// Creates the Filament viewer once and applies the scene-wide setup.
  Future<void> _initViewer() async {
    try {
      final viewer = await ThermionFlutterPlugin.createViewer();
      await viewer.setPostProcessing(true);
      await viewer.setAntiAliasing(false, true, false); // FXAA only
      await viewer.setBackgroundColor(
        widget.background.r,
        widget.background.g,
        widget.background.b,
        1.0,
      );
      // A single directional "sun" so the PBR material is shaded (no IBL/skybox
      // is loaded, so an unlit scene would render flat/black).
      await viewer.addDirectLight(
        DirectLight.sun(
          direction: Vector3(0.3, -0.8, 0.5)..normalize(),
          intensity: 80000,
          castShadows: false,
        ),
      );
      final camera = await viewer.getActiveCamera();
      if (!mounted) {
        await viewer.dispose();
        return;
      }
      _viewer = viewer;
      _camera = camera;
      _viewerReady = true;
      if (_pending != null) {
        await _upload();
      }
    } catch (e) {
      if (mounted) widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  Future<void> _load() async {
    widget.onStatus(const ModelSceneStatus(loading: true));
    try {
      final prepared = await compute(
        _prepareModelEntry,
        _ParseRequest(widget.filePath, widget.format),
      );
      if (!mounted) return;
      _pending = prepared;
      if (_viewerReady) await _upload();
    } catch (e) {
      if (!mounted) return;
      widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  /// Uploads the pending model to the GPU, framing the camera to it.
  Future<void> _upload() async {
    final viewer = _viewer;
    final p = _pending;
    if (viewer == null || p == null) return;
    try {
      // Replace any previous model (prev/next navigation).
      final old = _asset;
      if (old != null) {
        await viewer.destroyAsset(old);
        _asset = null;
        _material = null;
      }

      final geometry = Geometry(
        p.positions,
        p.indices,
        normals: p.normals,
        uvs: p.uvs,
        indexType: p.indexType,
      );

      final material = await FilamentApp.instance!.createUbershaderMaterialInstance();
      await material.setParameterFloat4('baseColorFactor', 0.82, 0.82, 0.86, 1.0);
      // OBJ/STL winding is inconsistent — draw both faces.
      await material.setCullingMode(CullingMode.NONE);

      final asset = await viewer.createGeometry(
        geometry,
        materialInstances: [material],
        releaseSourceData: true,
      );
      _asset = asset;
      _material = material;

      // Center the model at the origin so the orbit pivot + framing are stable.
      await FilamentApp.instance!.setTransform(
        asset.entity,
        Matrix4.translation(Vector3(-p.centerX, -p.centerY, -p.centerZ)),
      );
      await viewer.addToScene(asset);

      // Frame the camera: iso view at a comfortable distance, with zoom limits.
      final modelRadius = p.camDistance / 3.0; // camDistance == radius * 3
      _radius = p.camDistance;
      _startRadius = _radius;
      _minRadius = math.max(modelRadius * 0.4, 0.05);
      _maxRadius = p.camDistance * 5.0;
      _azimuth = _isoAzimuth;
      _elevation = _isoElevation;
      await _applyCameraNow();

      _pending = null; // drop the CPU-side copy now it's on the GPU
      _hasModel = true;
      if (mounted) setState(() {});
      widget.onStatus(
        ModelSceneStatus(
          loading: false,
          verts: p.vertexCount,
          tris: p.triangleCount,
          parseMs: p.parseMs,
        ),
      );
    } catch (e) {
      if (mounted) widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  // --- Camera control -------------------------------------------------------

  /// Camera position on the sphere around the origin, from the orbit angles.
  Vector3 _orbitPosition() {
    final ce = math.cos(_elevation);
    return Vector3(
      _radius * ce * math.sin(_azimuth),
      _radius * math.sin(_elevation),
      _radius * ce * math.cos(_azimuth),
    );
  }

  /// Applies the current orbit pose immediately (used for framing/presets).
  Future<void> _applyCameraNow() async {
    final cam = _camera;
    if (cam == null) return;
    await cam.lookAt(_orbitPosition(), focus: Vector3.zero(), up: Vector3(0, 1, 0));
  }

  /// Requests a camera update, coalescing rapid gesture deltas so async lookAt
  /// calls never queue up.
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
        await cam.lookAt(_orbitPosition(),
            focus: Vector3.zero(), up: Vector3(0, 1, 0));
      }
    } finally {
      _applyingCamera = false;
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startRadius = _radius;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // Pinch → zoom (radius is relative to the gesture-start radius).
    if (d.scale != 1.0) {
      _radius = (_startRadius / d.scale).clamp(_minRadius, _maxRadius);
    }
    // Drag → rotate. focalPointDelta is the per-update movement in px.
    final dp = d.focalPointDelta;
    if (dp != Offset.zero) {
      _azimuth -= dp.dx * _rotSpeed;
      _elevation =
          (_elevation + dp.dy * _rotSpeed).clamp(-_elevationLimit, _elevationLimit);
    }
    _requestCamera();
  }

  static const double _rotSpeed = 0.01; // rad per px — tuned for a free feel

  /// Snaps the camera to a preset direction, keeping the current radius.
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
    await _applyCameraNow();
  }

  /// Sets the model's base color (linear RGB; the light shades it).
  Future<void> _setColor(Color color) async {
    await _material?.setParameterFloat4(
        'baseColorFactor', color.r, color.g, color.b, 1.0);
  }

  // Render-mode swap. Solid is the only mode this build renders; wireframe and
  // x-ray land in the follow-up alongside thumbnail capture.
  void _setRenderMode(String mode) {
    // Intentionally a no-op for now (solid). Kept so the host's Render panel
    // chips don't break the controller contract.
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    if (!_hasModel || viewer == null) {
      // Still creating the viewer / parsing — host shows the spinner over this.
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
  const _ParseRequest(this.path, this.format);
  final String path;
  final String format;
}

/// Parsed model, de-interleaved into Filament's separate attribute buffers.
/// All fields are isolate-transferable (typed lists / primitives).
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
  });

  final Float32List positions; // 3 floats / vertex
  final Float32List normals; // 3 floats / vertex
  final Float32List uvs; // 2 floats / vertex
  final List<int> indices; // Uint16List or Uint32List
  final IndexType indexType;
  final int vertexCount;
  final int triangleCount;
  final double centerX, centerY, centerZ;
  final double camDistance;
  final int parseMs;
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
  );
}
