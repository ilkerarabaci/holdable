import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../data/model_parser.dart';
import '../data/scene_geometry.dart';

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

/// Imperative handle for the host screen to drive the GPU view (render mode,
/// preset camera, thumbnail capture) without rebuilding it.
class ModelSceneController {
  _ModelSceneViewState? _state;

  void _attach(_ModelSceneViewState s) => _state = s;
  void _detach(_ModelSceneViewState s) {
    if (identical(_state, s)) _state = null;
  }

  void setRenderMode(String mode) => _state?._setRenderMode(mode);
  void setView(String preset) => _state?._setPreset(preset);
}

/// Native flutter_scene 3D view: parses the model off the UI isolate, uploads
/// it to the GPU, and renders it in an orbit-controllable scene. Replaces the
/// WebView/three.js viewer (ADR-001) to drop the Chromium memory floor.
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

class _ModelSceneViewState extends State<ModelSceneView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  Scene? _scene;
  Node? _node;
  bool _ready = false;

  // Orbit camera state (spherical around [_target]).
  double _azimuth = math.pi / 4;
  double _elevation = 0.5;
  double _distance = 5;
  double _defaultDistance = 5;
  double _radius = 1;
  vm.Vector3 _target = vm.Vector3.zero();
  double _zoomStartDistance = 5;

  String _mode = 'solid';

  /// On-demand rendering: instead of drawing 60fps forever (which keeps
  /// Impeller's Vulkan allocator hot and inflates graphics PSS), we only render
  /// in short bursts after something changes — load, orbit, mode/preset. When
  /// idle the ticker stops and the GPU pool can be reclaimed.
  int _renderFramesLeft = 0;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    _ticker = createTicker(_onTick); // started on demand, not continuously
    _init();
  }

  void _onTick(Duration _) {
    _frame.value++;
    if (--_renderFramesLeft <= 0) _ticker.stop();
  }

  /// Render for the next [frames] frames (~16ms each), then idle.
  void _requestRender([int frames = 30]) {
    if (frames > _renderFramesLeft) _renderFramesLeft = frames;
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void didUpdateWidget(ModelSceneView old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath && _ready) {
      _load();
    }
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    _ticker.dispose();
    _frame.dispose();
    _node = null;
    _scene = null;
    super.dispose();
  }

  Future<void> _init() async {
    await Scene.initializeStaticResources();
    if (!mounted) return;
    _scene = Scene()
      // MSAA 4x render targets are huge on high-res phones (~4-5x the memory of
      // a single-sample target, ×frames-in-flight) — the dominant memory cost.
      // Off keeps the GPU footprint sane; we can revisit edge-AA later.
      ..antiAliasingMode = AntiAliasingMode.none;
    _ready = true;
    await _load();
  }

  Future<void> _load() async {
    widget.onStatus(const ModelSceneStatus(loading: true));
    try {
      final parsed = await compute(
        _parseModelEntry,
        _ParseRequest(widget.filePath, widget.format),
      );
      if (!mounted) return;

      final geometry = SceneGeometry.fromMeshData(parsed.mesh);
      _node = Node(mesh: Mesh(geometry, _materialFor(_mode)));
      _scene!
        ..removeAll()
        ..add(_node!);

      _frameModel(parsed.mesh.bounds);
      _requestRender(90); // ~1.5s to upload, settle, and capture the thumbnail

      widget.onStatus(
        ModelSceneStatus(
          loading: false,
          verts: parsed.mesh.vertexCount,
          tris: parsed.mesh.triangleCount,
          parseMs: parsed.parseMs,
        ),
      );

      // Capture a thumbnail once the model has had a couple frames to settle.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _captureThumbnail();
      });
    } catch (e) {
      if (!mounted) return;
      widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  /// Frames the camera to fit [bounds] with a default isometric angle.
  void _frameModel(ModelBounds bounds) {
    _target = vm.Vector3(bounds.centerX, bounds.centerY, bounds.centerZ);
    final diag = math.sqrt(
      bounds.sizeX * bounds.sizeX +
          bounds.sizeY * bounds.sizeY +
          bounds.sizeZ * bounds.sizeZ,
    );
    _radius = diag > 1e-6 ? diag / 2 : 1.0;
    // distance so the bounding sphere fits the vertical FOV, with margin.
    _defaultDistance = _radius / math.sin(_kFovY / 2) * 1.3;
    _distance = _defaultDistance;
    _azimuth = math.pi / 4;
    _elevation = 0.5;
  }

  void _setRenderMode(String mode) {
    _mode = mode;
    final node = _node;
    if (node?.mesh != null) {
      node!.mesh!.primitives.first.material = _materialFor(mode);
    }
    _requestRender();
  }

  void _setPreset(String preset) {
    switch (preset) {
      case 'front':
        _azimuth = 0;
        _elevation = 0;
      case 'side':
        _azimuth = math.pi / 2;
        _elevation = 0;
      case 'top':
        _azimuth = 0;
        _elevation = math.pi / 2 - 0.06; // avoid a degenerate look-at
      case 'iso':
      default:
        _azimuth = math.pi / 4;
        _elevation = 0.5;
    }
    _distance = _defaultDistance;
    _requestRender();
  }

  Material _materialFor(String mode) {
    switch (mode) {
      case 'wireframe':
        return _WireMaterial(vm.Vector4(0.545, 0.424, 1.0, 1.0)); // violet
      case 'xray':
        return _XrayMaterial(vm.Vector4(0.31, 0.878, 0.898, 0.3)); // cyan
      case 'solid':
      default:
        return _SolidMaterial(vm.Vector4(0.85, 0.84, 0.90, 1.0));
    }
  }

  vm.Vector3 _cameraPosition() {
    final dir = vm.Vector3(
      math.cos(_elevation) * math.sin(_azimuth),
      math.sin(_elevation),
      math.cos(_elevation) * math.cos(_azimuth),
    );
    return _target + dir * _distance;
  }

  PerspectiveCamera _camera() {
    final near = math.max(0.01, _distance - _radius * 2);
    final far = _distance + _radius * 3 + 1;
    return PerspectiveCamera(
      fovRadiansY: _kFovY,
      position: _cameraPosition(),
      target: _target,
      up: vm.Vector3(0, 1, 0),
      fovNear: near,
      fovFar: far,
    );
  }

  /// Last on-screen viewport size, reused for thumbnail capture so the GPU
  /// Surface isn't forced to reallocate render targets at a different size.
  ui.Size _lastSize = const ui.Size(512, 512);

  /// Renders the current scene into [canvas]. Called by [_ScenePainter].
  void renderInto(ui.Canvas canvas, ui.Size size) {
    // Theme background shows through the scene's transparent clear color.
    canvas.drawColor(widget.background, ui.BlendMode.src);
    final scene = _scene;
    if (!_ready || scene == null || size.isEmpty) return;
    if (size != _lastSize) _requestRender(2); // size changed (e.g. rotation)
    _lastSize = size;
    scene.render(_camera(), canvas, viewport: ui.Offset.zero & size);
  }

  Future<void> _captureThumbnail() async {
    final scene = _scene;
    final onThumb = widget.onThumbnail;
    if (scene == null || onThumb == null) return;
    // Render at the live viewport size (no Surface size change → no render-target
    // reallocation), then downscale the resulting image to a 256px thumbnail.
    final w = _lastSize.width.round().clamp(64, 2048);
    final h = _lastSize.height.round().clamp(64, 2048);
    const dim = 256;
    try {
      final recorder = ui.PictureRecorder();
      final rect = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      final canvas = ui.Canvas(recorder, rect);
      canvas.drawColor(widget.background, ui.BlendMode.src);
      scene.render(_camera(), canvas, viewport: rect);
      final picture = recorder.endRecording();
      final full = await picture.toImage(w, h);
      picture.dispose();

      // Downscale (centered square crop) to the thumbnail size on the CPU path.
      final side = math.min(w, h).toDouble();
      final src = ui.Rect.fromLTWH((w - side) / 2, (h - side) / 2, side, side);
      final rec2 = ui.PictureRecorder();
      final c2 = ui.Canvas(rec2);
      c2.drawImageRect(
        full,
        src,
        const ui.Rect.fromLTWH(0, 0, 256, 256),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final pic2 = rec2.endRecording();
      final small = await pic2.toImage(dim, dim);
      pic2.dispose();
      full.dispose();

      final data = await small.toByteData(format: ui.ImageByteFormat.png);
      small.dispose();
      if (data == null || !mounted) return;
      onThumb(data.buffer.asUint8List());
    } catch (_) {
      // Best-effort; a missing thumbnail just falls back to the placeholder.
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (_) => _zoomStartDistance = _distance,
      onScaleUpdate: (details) {
        _azimuth -= details.focalPointDelta.dx * 0.01;
        _elevation =
            (_elevation + details.focalPointDelta.dy * 0.01).clamp(-1.5, 1.5);
        if ((details.scale - 1).abs() > 1e-3) {
          _distance = (_zoomStartDistance / details.scale)
              .clamp(_radius * 0.4, _radius * 25);
        }
        _requestRender(20); // keep drawing through the gesture
      },
      child: CustomPaint(
        painter: _ScenePainter(this, _frame),
        isComplex: true,
        willChange: true,
        child: const SizedBox.expand(),
      ),
    );
  }
}

const double _kFovY = 45 * vm.degrees2Radians;

class _ScenePainter extends CustomPainter {
  _ScenePainter(this._view, Listenable repaint) : super(repaint: repaint);

  final _ModelSceneViewState _view;

  @override
  void paint(ui.Canvas canvas, ui.Size size) => _view.renderInto(canvas, size);

  // Repaint ONLY when the frame notifier fires (on-demand bursts) — not on every
  // parent rebuild. Otherwise unrelated setState (e.g. the PSS poll) would force
  // a GPU render and defeat on-demand rendering.
  @override
  bool shouldRepaint(covariant _ScenePainter old) => false;
}

// -----------------------------------------------------------------------------
// Render-mode materials
//
// The flutter_scene encoder calls `material.bind()` immediately before the draw
// call, so overriding `bind` is the injection point for per-mode GPU state:
//   * cull mode -> none, since imported OBJ/STL winding is inconsistent;
//   * polygon mode -> line for wireframe (fill otherwise);
//   * a base-color alpha < 1 makes a material translucent (isOpaque() == false),
//     routing it through the encoder's blended pass -> the x-ray look.
// -----------------------------------------------------------------------------

class _SolidMaterial extends PhysicallyBasedMaterial {
  _SolidMaterial(vm.Vector4 color) {
    baseColorFactor = color;
    metallicFactor = 0.0;
    roughnessFactor = 0.65;
    vertexColorWeight = 0.0;
  }

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    Environment environment,
  ) {
    super.bind(pass, transientsBuffer, environment);
    pass.setCullMode(gpu.CullMode.none);
    pass.setPolygonMode(gpu.PolygonMode.fill);
  }
}

class _XrayMaterial extends PhysicallyBasedMaterial {
  _XrayMaterial(vm.Vector4 color) {
    baseColorFactor = color; // alpha < 1 -> translucent
    metallicFactor = 0.0;
    roughnessFactor = 0.5;
    vertexColorWeight = 0.0;
    emissiveFactor = vm.Vector4(0.10, 0.28, 0.30, 1.0);
  }

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    Environment environment,
  ) {
    super.bind(pass, transientsBuffer, environment);
    pass.setCullMode(gpu.CullMode.none);
    pass.setPolygonMode(gpu.PolygonMode.fill);
  }
}

class _WireMaterial extends UnlitMaterial {
  _WireMaterial(vm.Vector4 color) {
    baseColorFactor = color;
    vertexColorWeight = 0.0;
  }

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    Environment environment,
  ) {
    super.bind(pass, transientsBuffer, environment);
    pass.setCullMode(gpu.CullMode.none);
    pass.setPolygonMode(gpu.PolygonMode.line);
  }
}

// -----------------------------------------------------------------------------
// Off-isolate parsing
// -----------------------------------------------------------------------------

class _ParseRequest {
  const _ParseRequest(this.path, this.format);
  final String path;
  final String format;
}

/// Result of parsing on a background isolate.
class ParsedModel {
  ParsedModel(this.mesh, this.parseMs);
  final MeshData mesh;
  final int parseMs;
}

/// Isolate entry point: reads + parses the file, timing only the parse.
ParsedModel _parseModelEntry(_ParseRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final sw = Stopwatch()..start();
  final mesh = ModelParser.parse(bytes, format: req.format);
  sw.stop();
  return ParsedModel(mesh, sw.elapsedMilliseconds);
}
