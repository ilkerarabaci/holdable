import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

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
/// preset camera). Implemented by the active renderer.
class ModelSceneController {
  _ModelSceneViewState? _state;

  void _attach(_ModelSceneViewState s) => _state = s;
  void _detach(_ModelSceneViewState s) {
    if (identical(_state, s)) _state = null;
  }

  void setRenderMode(String mode) => _state?._setRenderMode(mode);
  void setView(String preset) => _state?._setPreset(preset);
}

/// 3D viewer surface.
///
/// **v0.3 (Thermion/Filament) — work in progress.** The flutter_scene renderer
/// (v0.2, tag `v0.2.0-alpha-flutterscene`) was frozen after device testing
/// showed an Impeller GPU-memory floor we can't control (ADR-002). This is the
/// scaffold for the Thermion-based viewer: it still parses the model off the UI
/// isolate (the parser is renderer-agnostic) and reports stats, while the
/// Filament render surface is wired up. Keeps the same widget contract so the
/// host [ViewerScreen] is unchanged.
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
  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
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
    super.dispose();
  }

  // Render-mode / preset hooks land when the Filament view is wired in.
  void _setRenderMode(String mode) {}
  void _setPreset(String preset) {}

  Future<void> _load() async {
    widget.onStatus(const ModelSceneStatus(loading: true));
    try {
      final parsed = await compute(
        _parseModelEntry,
        _ParseRequest(widget.filePath, widget.format),
      );
      if (!mounted) return;
      widget.onStatus(
        ModelSceneStatus(
          loading: false,
          verts: parsed.mesh.vertexCount,
          tris: parsed.mesh.triangleCount,
          parseMs: parsed.parseMs,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      widget.onStatus(ModelSceneStatus(loading: false, error: '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: widget.background);
  }
}

// -----------------------------------------------------------------------------
// Off-isolate parsing (renderer-agnostic; reused across renderer lines)
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
