import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/widgets/ar_view.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// AR-1 "View in AR" (ADR-003): place the model on a real surface, walk around
/// it, drag/rotate it. The model is handed in as a `.glb` at [glbAbsolutePath]
/// (already written to the app's documents folder by ar_export.dart).
///
/// Uses ar_flutter_plugin_2 (ARCore / ARKit via SceneView, its own Filament
/// renderer — so this shows a plainly-lit GLB, not Holdable's render modes).
/// One model at a time: tapping a new surface re-places it.
///
/// Loading note: the plugin's `fileSystemAppFolderGLB` doesn't resolve a
/// relative name (its native branch is a no-op), and SceneView's loader won't
/// read a bare absolute path — but it DOES resolve a `file://` URI, so that's
/// what we pass. (Confirmed on device: a bare path → addNode false; `file://` →
/// the model appears.)
class ArViewScreen extends StatefulWidget {
  const ArViewScreen({
    super.key,
    required this.glbAbsolutePath,
    required this.title,
  });

  final String glbAbsolutePath;
  final String title;

  @override
  State<ArViewScreen> createState() => _ArViewScreenState();
}

class _ArViewScreenState extends State<ArViewScreen>
    with WidgetsBindingObserver {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;
  ARNode? _node;
  ARAnchor? _anchor;
  bool _placed = false;
  double _scale = 0.2; // current placed scale
  double _rotationY = 0.0; // current placed yaw (radians)
  vm.Matrix4? _baseTransform; // the tapped surface pose (before our Y rotation)
  // This plugin's native side ignores a node's rotation — it reads ONLY the
  // first transform element as a uniform scale (scaleToUnits). So rotation can't
  // go on the node (passing one corrupts the scale: m00 = scale·cos(yaw), which
  // is why rotating "resized" the model). Instead we apply scale on the node and
  // ROTATE THE ANCHOR (the node inherits the anchor's pose) — see _rebuildPlacement.

  @override
  void initState() {
    super.initState();
    // Watch app lifecycle so we can pause the AR session when backgrounded —
    // a running ARCore/ARKit session is a major heat/battery source even with
    // the app off-screen (PO #2 overheating).
    WidgetsBinding.instance.addObserver(this);
  }

  /// Pause the camera + AR tracking when the app leaves the foreground and
  /// resume it on return. The plugin's disableCamera()/enableCamera() map to
  /// the native session.pause()/resume(), which also stops per-frame tracking.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _sessionManager?.disableCamera();
      case AppLifecycleState.resumed:
        _sessionManager?.enableCamera();
      case AppLifecycleState.detached:
        break;
    }
  }

  ARNode _makeNode() => ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        uri: 'file://${widget.glbAbsolutePath}',
        scale: vm.Vector3.all(_scale), // clean uniform scale, no rotation
        position: vm.Vector3.zero(),
      );

  /// Removes any current placement and re-adds the anchor (rotated about its
  /// up-axis by _rotationY) + the node (scaled). This is how both rotate and
  /// resize take effect, given the plugin's transform limitations.
  Future<bool> _rebuildPlacement() async {
    final objects = _objectManager, anchors = _anchorManager;
    final base = _baseTransform;
    if (objects == null || anchors == null || base == null) return false;
    if (_node != null) await objects.removeNode(_node!);
    if (_anchor != null) await anchors.removeAnchor(_anchor!);
    _node = null;
    _anchor = null;

    final anchor = ARPlaneAnchor(
      transformation: base.clone()..multiply(vm.Matrix4.rotationY(_rotationY)),
    );
    if (await anchors.addAnchor(anchor) != true) return false;
    _anchor = anchor;

    final node = _makeNode();
    final added = await objects.addNode(node, planeAnchor: anchor);
    if (added == true) {
      _node = node;
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionManager?.dispose();
    super.dispose();
  }

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _sessionManager = sessionManager;
    _objectManager = objectManager;
    _anchorManager = anchorManager;
    sessionManager.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      handleTaps: true,
      handlePans: true, // drag the placed model
      handleRotation: true, // two-finger rotate the placed model
    );
    objectManager.onInitialize();
    sessionManager.onPlaneOrPointTap = _onPlaneTap;
  }

  Future<void> _onPlaneTap(List<ARHitTestResult> hits) async {
    final objects = _objectManager, anchors = _anchorManager;
    if (objects == null || anchors == null) return;

    // Prefer a real plane hit; fall back to any hit.
    final planeHits =
        hits.where((h) => h.type == ARHitTestResultType.plane).toList();
    final hit = planeHits.isNotEmpty
        ? planeHits.first
        : (hits.isNotEmpty ? hits.first : null);
    if (hit == null) return;

    try {
      // Tap (re)places at the new surface point, keeping the current scale +
      // rotation. The base pose is the hit; our Y rotation is layered on in
      // _rebuildPlacement.
      _baseTransform = hit.worldTransform;
      final ok = await _rebuildPlacement();
      if (ok && mounted) {
        // Stop finding/drawing planes once the model is placed: the plane
        // renderer runs continuously and is a steady heat source (PO #2). It's
        // turned back on in _reset() so the user can re-place.
        _sessionManager?.showPlanes(false);
        setState(() => _placed = true);
      } else if (mounted) {
        _toast("Couldn't place the model here.");
      }
    } catch (_) {
      _toast("Couldn't place the model.");
    }
  }

  /// Resize the placed model (×factor).
  Future<void> _rescale(double factor) async {
    if (!_placed) return;
    final next = (_scale * factor).clamp(0.02, 2.0);
    if (next == _scale) return;
    _scale = next;
    if (await _rebuildPlacement() && mounted) setState(() {});
  }

  /// Rotate the placed model about its vertical (surface) axis by [deltaRad].
  Future<void> _rotate(double deltaRad) async {
    if (!_placed) return;
    _rotationY += deltaRad;
    if (await _rebuildPlacement() && mounted) setState(() {});
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _reset() {
    final objects = _objectManager, anchors = _anchorManager;
    if (_node != null) objects?.removeNode(_node!);
    if (_anchor != null) anchors?.removeAnchor(_anchor!);
    _node = null;
    _anchor = null;
    // Re-enable plane finding/drawing so the user can pick a new spot (we
    // switched it off after the previous placement to save heat/battery).
    _sessionManager?.showPlanes(true);
    setState(() => _placed = false);
  }

  /// Captures the live AR scene (camera + placed model) and opens the share
  /// sheet with it as a PNG — so a model-in-your-room shot can be saved or sent.
  Future<void> _captureAndShare() async {
    final session = _sessionManager;
    if (session == null) return;
    try {
      final image = await session.snapshot();
      if (image is! MemoryImage) {
        _toast("Couldn't capture the AR view.");
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/holdable_ar_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(image.bytes);
      if (!mounted) return;
      // iPad needs a popover origin; a safe centre rect avoids the RenderSliver
      // cast pitfall (see library_screen share).
      Rect? origin;
      final size = MediaQuery.maybeOf(context)?.size;
      if (size != null) {
        origin = Rect.fromCenter(
            center: size.center(Offset.zero), width: 1, height: 1);
      }
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        subject: widget.title,
        sharePositionOrigin: origin,
      );
    } catch (_) {
      _toast("Couldn't capture the AR view.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Capture & share',
            onPressed: _captureAndShare,
            icon: const Icon(Icons.camera_alt_outlined),
          ),
          if (_placed)
            IconButton(
              tooltip: 'Remove',
              onPressed: _reset,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          if (!_placed)
            Positioned(
              left: 12,
              right: 12,
              bottom: 36,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    'Point at a floor or table, then tap to place',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          if (_placed)
            Positioned(
              left: 12,
              right: 12,
              bottom: 96, // lifted clear of the system nav bar / thumb zone
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Tap a new spot to move it',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  // Two separated groups so rotate and resize don't get mixed up,
                  // with big touch targets.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ArControlGroup(label: 'ROTATE', children: [
                        _ArBtn(
                          tooltip: 'Rotate left',
                          icon: Icons.rotate_left,
                          onTap: () => _rotate(-0.5236), // -30°
                        ),
                        _ArBtn(
                          tooltip: 'Rotate right',
                          icon: Icons.rotate_right,
                          onTap: () => _rotate(0.5236), // +30°
                        ),
                      ]),
                      const SizedBox(width: 22),
                      _ArControlGroup(label: 'SIZE', children: [
                        _ArBtn(
                          tooltip: 'Smaller',
                          icon: Icons.zoom_out,
                          onTap: () => _rescale(0.8),
                        ),
                        _ArBtn(
                          tooltip: 'Bigger',
                          icon: Icons.zoom_in,
                          onTap: () => _rescale(1.25),
                        ),
                      ]),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A labelled pill grouping two AR control buttons.
class _ArControlGroup extends StatelessWidget {
  const _ArControlGroup({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(34),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// A large, finger-friendly round AR control button.
class _ArBtn extends StatelessWidget {
  const _ArBtn(
      {required this.tooltip, required this.icon, required this.onTap});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
      ),
    );
  }
}
