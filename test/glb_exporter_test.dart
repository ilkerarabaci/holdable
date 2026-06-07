import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/ar/data/glb_exporter.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';

/// A minimal non-indexed (STL-like) mesh: one triangle, interleaved 12-float
/// vertices [pos3, normal3, uv2, color4].
MeshData _oneTriangle() {
  final v = Float32List(3 * kFloatsPerVertex);
  void put(int i, double px, double py, double pz) {
    final s = i * kFloatsPerVertex;
    v[s] = px;
    v[s + 1] = py;
    v[s + 2] = pz;
    v[s + 3] = 0; // nx
    v[s + 4] = 0; // ny
    v[s + 5] = 1; // nz
  }

  put(0, 0, 0, 0);
  put(1, 2, 0, 0);
  put(2, 0, 3, 0);
  return MeshData(
    vertices: v,
    vertexCount: 3,
    triangleCount: 1,
    bounds: const ModelBounds(0, 0, 0, 2, 3, 0),
  );
}

/// Extracts and decodes the glTF JSON chunk from GLB bytes.
Map<String, dynamic> _readGltfJson(Uint8List glb) {
  final bd = ByteData.sublistView(glb);
  expect(bd.getUint32(0, Endian.little), 0x46546C67); // 'glTF'
  expect(bd.getUint32(4, Endian.little), 2); // version 2
  expect(bd.getUint32(8, Endian.little), glb.length); // total length
  final jsonLen = bd.getUint32(12, Endian.little);
  expect(bd.getUint32(16, Endian.little), 0x4E4F534A); // 'JSON'
  final jsonBytes = glb.sublist(20, 20 + jsonLen);
  return json.decode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
}

void main() {
  group('glbFromMesh', () {
    test('emits a valid GLB container (magic, version, total length)', () {
      final glb = glbFromMesh(_oneTriangle());
      // _readGltfJson asserts the header; also check 4-byte alignment + chunks.
      final gltf = _readGltfJson(glb);
      expect(glb.length % 4, 0);
      expect(gltf['asset']['version'], '2.0');
    });

    test('describes one mesh/primitive with POSITION, NORMAL and indices', () {
      final gltf = _readGltfJson(glbFromMesh(_oneTriangle()));
      final prim = gltf['meshes'][0]['primitives'][0];
      expect(prim['attributes']['POSITION'], 0);
      expect(prim['attributes']['NORMAL'], 1);
      expect(prim['indices'], 2);
      expect(prim['material'], 0);
    });

    test('accessors: POSITION has count + AABB min/max, indices count = tris*3',
        () {
      final gltf = _readGltfJson(glbFromMesh(_oneTriangle()));
      final acc = gltf['accessors'] as List;
      expect(acc[0]['count'], 3); // 3 vertices
      expect(acc[0]['type'], 'VEC3');
      expect((acc[0]['min'] as List).cast<num>(), [0, 0, 0]);
      expect((acc[0]['max'] as List).cast<num>(), [2, 3, 0]);
      expect(acc[2]['count'], 3); // 1 triangle * 3
      expect(acc[2]['type'], 'SCALAR');
    });

    test('buffer byteLength matches the BIN chunk length', () {
      final glb = glbFromMesh(_oneTriangle());
      final gltf = _readGltfJson(glb);
      final bd = ByteData.sublistView(glb);
      final jsonLen = bd.getUint32(12, Endian.little);
      final binChunkOffset = 12 + 8 + jsonLen;
      final binLen = bd.getUint32(binChunkOffset, Endian.little);
      expect(bd.getUint32(binChunkOffset + 4, Endian.little), 0x004E4942); // BIN
      expect(gltf['buffers'][0]['byteLength'], binLen);
      // BIN holds 3 verts * (12 pos + 12 normal) + 3 indices * 2 bytes = 78 → pad to 80.
      expect(binLen, 80);
    });

    test('round-trips a real parsed STL into a non-empty GLB', () {
      // Build a tiny binary STL (1 triangle) and parse it, then export.
      final stl = ByteData(84 + 50);
      stl.setUint32(80, 1, Endian.little); // triangle count
      // normal (0,0,1) then 3 verts; leave most as zeros, set a couple coords.
      stl.setFloat32(84 + 8, 1.0, Endian.little); // nz
      stl.setFloat32(84 + 12 + 0, 0.0, Endian.little); // v0.x
      stl.setFloat32(84 + 24 + 0, 1.0, Endian.little); // v1.x
      stl.setFloat32(84 + 36 + 4, 1.0, Endian.little); // v2.y
      final mesh = ModelParser.parse(stl.buffer.asUint8List(), format: 'stl');
      final glb = glbFromMesh(mesh);
      final gltf = _readGltfJson(glb);
      expect(gltf['meshes'], isNotEmpty);
      expect(gltf['accessors'][2]['count'], mesh.triangleCount * 3);
    });
  });
}
