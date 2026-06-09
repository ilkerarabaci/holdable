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
import 'package:flutter/material.dart';
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

class _ArViewScreenState extends State<ArViewScreen> {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;
  ARNode? _node;
  ARAnchor? _anchor;
  bool _placed = false;
  double _scale = 0.2; // current placed scale
  double _rotationY = 0.0; // current placed yaw (radians)
  // The plugin has no runtime node-transform method (only addNode/removeNode),
  // so scale + rotation are applied by re-adding the node on the same anchor.

  ARNode _makeNode() => ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        uri: 'file://${widget.glbAbsolutePath}',
        scale: vm.Vector3.all(_scale),
        rotation: vm.Vector4(0, 1, 0, _rotationY), // axis-angle about Y
        position: vm.Vector3.zero(),
      );

  @override
  void dispose() {
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
      // One model at a time — clear the previous placement.
      if (_node != null) objects.removeNode(_node!);
      if (_anchor != null) anchors.removeAnchor(_anchor!);
      _node = null;
      _anchor = null;

      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      if (await anchors.addAnchor(anchor) != true) {
        _toast("Couldn't anchor here — try another spot.");
        return;
      }
      _anchor = anchor;

      final node = _makeNode();
      final added = await objects.addNode(node, planeAnchor: anchor);
      if (added == true && mounted) {
        _node = node;
        setState(() => _placed = true);
      } else {
        _toast("Couldn't place the model here.");
      }
    } catch (_) {
      _toast("Couldn't place the model.");
    }
  }

  /// Re-adds the placed node on the SAME anchor with the current _scale/
  /// _rotationY (the plugin has no runtime node-transform method).
  Future<void> _replaceNode() async {
    final objects = _objectManager, anchor = _anchor;
    if (!_placed || objects == null || anchor is! ARPlaneAnchor) return;
    if (_node != null) await objects.removeNode(_node!);
    final node = _makeNode();
    final added = await objects.addNode(node, planeAnchor: anchor);
    if (added == true && mounted) {
      _node = node;
      setState(() {});
    }
  }

  /// Resize the placed model (×factor).
  Future<void> _rescale(double factor) async {
    final next = (_scale * factor).clamp(0.02, 2.0);
    if (next == _scale) return;
    _scale = next;
    await _replaceNode();
  }

  /// Rotate the placed model about its vertical axis by [deltaRad].
  Future<void> _rotate(double deltaRad) async {
    if (!_placed) return;
    _rotationY += deltaRad;
    await _replaceNode();
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
    setState(() => _placed = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
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
              bottom: 28,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Tap a new spot to move it',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Rotate left',
                            color: Colors.white,
                            onPressed: () => _rotate(-0.5236), // -30°
                            icon: const Icon(Icons.rotate_left),
                          ),
                          IconButton(
                            tooltip: 'Smaller',
                            color: Colors.white,
                            onPressed: () => _rescale(0.8),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          const Icon(Icons.straighten,
                              color: Colors.white54, size: 16),
                          IconButton(
                            tooltip: 'Bigger',
                            color: Colors.white,
                            onPressed: () => _rescale(1.25),
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                          IconButton(
                            tooltip: 'Rotate right',
                            color: Colors.white,
                            onPressed: () => _rotate(0.5236), // +30°
                            icon: const Icon(Icons.rotate_right),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
