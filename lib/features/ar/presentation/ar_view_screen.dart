import 'dart:io';

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
/// it, drag/rotate it. The model is handed in as a `.glb` already written to the
/// app's documents folder ([glbFileName], a relative name) by ar_export.dart.
///
/// Uses ar_flutter_plugin_2 (ARCore / ARKit via SceneView, its own Filament
/// renderer — so this shows a plainly-lit GLB, not Holdable's render modes).
/// One model at a time: tapping a new surface re-places it.
class ArViewScreen extends StatefulWidget {
  const ArViewScreen({
    super.key,
    required this.glbFileName,
    required this.title,
  });

  final String glbFileName;
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
  // DIAGNOSTIC overlay: surfaces each placement step so a single on-device tap
  // tells us where it breaks (camera+tracking already work; placement doesn't).
  String _debug = 'Move the phone to scan, then tap a surface…';
  void _setDbg(String s) {
    if (mounted) setState(() => _debug = s);
  }

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
    try {
      final objects = _objectManager, anchors = _anchorManager;
      if (objects == null || anchors == null) {
        _setDbg('AR not ready');
        return;
      }
      final planeHits =
          hits.where((h) => h.type == ARHitTestResultType.plane).toList();
      final hit = planeHits.isNotEmpty
          ? planeHits.first
          : (hits.isNotEmpty ? hits.first : null);
      if (hit == null) {
        _setDbg('${hits.length} hits, 0 usable — scan the surface more');
        return;
      }

      // One model at a time — clear the previous placement.
      if (_node != null) objects.removeNode(_node!);
      if (_anchor != null) anchors.removeAnchor(_anchor!);
      _node = null;
      _anchor = null;

      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final anchored = await anchors.addAnchor(anchor);
      if (anchored != true) {
        _setDbg('hits=${hits.length} plane=${planeHits.length} '
            'anchored=$anchored (FAILED)');
        return;
      }
      _anchor = anchor;

      final f = File(widget.glbFileName);
      final exists = f.existsSync();
      final size = exists ? f.lengthSync() : -1;
      final node = ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        // SceneView's loadModelInstance didn't load a raw absolute path; try a
        // file:// URI (it does load http URLs, so URL-style may resolve).
        uri: 'file://${widget.glbFileName}',
        scale: vm.Vector3.all(0.2),
        position: vm.Vector3.zero(),
      );
      final added = await objects.addNode(node, planeAnchor: anchor);
      _setDbg('exists=$exists size=$size added=$added\n'
          'hits=${hits.length} plane=${planeHits.length} '
          'anchored=$anchored added=$added glb=${widget.glbFileName}');
      if (added == true && mounted) {
        _node = node;
        setState(() => _placed = true);
      }
    } catch (e) {
      _setDbg('ERROR: $e');
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
          // DIAGNOSTIC overlay: always shows the last tap's placement steps so a
          // single on-device tap reveals where placement breaks.
          Positioned(
              left: 12,
              right: 12,
              bottom: 36,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _debug,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
