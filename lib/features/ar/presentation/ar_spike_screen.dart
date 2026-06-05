import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/widgets/ar_view.dart';
import 'package:flutter/material.dart';

/// AR-1 build-compat **spike** (ADR-003) — a minimal ARView with horizontal
/// plane detection. Its only job is to prove `ar_flutter_plugin_2` (ARCore +
/// `arsceneview`, which is Filament-based) compiles and builds *alongside* the
/// Thermion native stack (also Filament) and the `file_picker 8.1.0` pin.
///
/// It is intentionally NOT wired into app navigation yet — product AR (place
/// the model on a surface, scale it, walk around it) only follows once the
/// build/runtime is de-risked on a real ARCore device. Treat this as scaffolding.
class ArSpikeScreen extends StatefulWidget {
  const ArSpikeScreen({super.key});

  @override
  State<ArSpikeScreen> createState() => _ArSpikeScreenState();
}

class _ArSpikeScreenState extends State<ArSpikeScreen> {
  ARSessionManager? _sessionManager;

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
    sessionManager.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      handleTaps: false,
    );
    objectManager.onInitialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR spike')),
      body: ARView(
        onARViewCreated: _onARViewCreated,
        planeDetectionConfig: PlaneDetectionConfig.horizontal,
      ),
    );
  }
}
