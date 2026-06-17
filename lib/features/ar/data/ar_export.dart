import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import '../../viewer/data/model_parser.dart';
import 'glb_exporter.dart';

/// Exports a model to a `.glb` in the app's documents folder for the AR layer
/// and returns its **absolute path** (or null on failure). Parsing + GLB
/// serialization run off the UI isolate.
///
/// [overrideColorArgb] (sRGB 0xAARRGGBB) and [opacity] bake the viewer's current
/// look into the AR model (Faz D / #10): the colour the user picked and its
/// x-ray transparency. When [overrideColorArgb] is null the model's own colour
/// is used, as before.
///
/// NOTE: ar_flutter_plugin_2 0.0.3's native `fileSystemAppFolderGLB` branch is a
/// no-op (`fileLocation = fileLocation`) — it does NOT prepend the documents dir
/// to a relative name, so a bare file name fails to load (the model never
/// appears; addNode returns false). It passes the uri verbatim to SceneView's
/// `modelLoader.loadModelInstance`, which accepts an absolute file path — so we
/// hand it the full path.
Future<String?> exportModelToGlb({
  required String filePath,
  required String format,
  int? overrideColorArgb,
  double opacity = 1.0,
}) async {
  try {
    final glb = await compute(
      _glbEntry,
      _GlbRequest(filePath, format, overrideColorArgb, opacity),
    );
    if (glb == null) return null;
    final docs = await getApplicationDocumentsDirectory();
    final path = '${docs.path}/holdable_ar.glb';
    await File(path).writeAsBytes(glb);
    return path;
  } catch (_) {
    return null;
  }
}

class _GlbRequest {
  const _GlbRequest(
      this.path, this.format, this.overrideColorArgb, this.opacity);
  final String path;
  final String format;
  final int? overrideColorArgb;
  final double opacity;
}

Uint8List? _glbEntry(_GlbRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final mesh = ModelParser.parse(bytes, format: req.format);
  // Bake the viewer's current colour (when the user picked one) + opacity into
  // the AR export so AR matches what they see; fall back to the model's own
  // colour otherwise (e.g. the orange chair stays orange).
  final color = req.overrideColorArgb ?? mesh.baseColorArgb;
  return glbFromMesh(mesh, baseColorArgb: color, opacity: req.opacity);
}
