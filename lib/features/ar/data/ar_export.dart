import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import '../../viewer/data/model_parser.dart';
import 'glb_exporter.dart';

/// Exports a model to a `.glb` in the app's documents folder for the AR layer
/// (ar_flutter_plugin_2 loads `NodeType.fileSystemAppFolderGLB` by a name
/// relative to that folder). Parsing + GLB serialization run off the UI isolate.
/// Returns the relative file name, or null on failure.
Future<String?> exportModelToGlb({
  required String filePath,
  required String format,
}) async {
  try {
    final glb = await compute(_glbEntry, _GlbRequest(filePath, format));
    if (glb == null) return null;
    final docs = await getApplicationDocumentsDirectory();
    const name = 'holdable_ar.glb';
    await File('${docs.path}/$name').writeAsBytes(glb);
    return name;
  } catch (_) {
    return null;
  }
}

class _GlbRequest {
  const _GlbRequest(this.path, this.format);
  final String path;
  final String format;
}

Uint8List? _glbEntry(_GlbRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final mesh = ModelParser.parse(bytes, format: req.format);
  return glbFromMesh(mesh);
}
