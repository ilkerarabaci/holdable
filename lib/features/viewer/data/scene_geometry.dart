import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';

import 'model_parser.dart';

/// Bridges the pure-Dart [MeshData] produced by [ModelParser] into a
/// flutter_scene [Geometry] living on the GPU.
///
/// Kept separate from [ModelParser] because this step requires a live
/// `gpu.gpuContext` (it allocates a device buffer), so it can't run in plain
/// unit tests — the parsing logic is tested independently.
class SceneGeometry {
  /// Uploads [mesh] into a new unskinned [Geometry]. Honors the index buffer
  /// when present (16- or 32-bit); otherwise builds a non-indexed geometry.
  static Geometry fromMeshData(MeshData mesh) {
    final geometry = UnskinnedGeometry();

    ByteData? indices;
    var indexType = gpu.IndexType.int16;
    if (mesh.indices16 != null) {
      indices = ByteData.sublistView(mesh.indices16!);
      indexType = gpu.IndexType.int16;
    } else if (mesh.indices32 != null) {
      indices = ByteData.sublistView(mesh.indices32!);
      indexType = gpu.IndexType.int32;
    }

    geometry.uploadVertexData(
      ByteData.sublistView(mesh.vertices),
      mesh.vertexCount,
      indices,
      indexType: indexType,
    );
    return geometry;
  }
}
