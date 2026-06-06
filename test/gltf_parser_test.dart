import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/gltf_parser.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';

/// Builds a minimal valid GLB with one triangle (positions 0,0,0 / 2,0,0 /
/// 0,3,0), optionally indexed, with an optional node translation/scale, so the
/// parser is tested against hand-crafted glTF (not a round-trip of our exporter).
Uint8List _glb({
  List<double>? translation,
  double scale = 1.0,
  bool indexed = true,
  bool draco = false,
}) {
  final pos = Float32List.fromList([0, 0, 0, 2, 0, 0, 0, 3, 0]);
  final posBytes = pos.buffer.asUint8List();
  final idx = Uint16List.fromList([0, 1, 2]);
  final idxBytes = idx.buffer.asUint8List();

  // BIN: positions [0,36) then (if indexed) indices [36,42), padded to 4.
  final binUnpadded = indexed ? 36 + 6 : 36;
  final binLen = (binUnpadded + 3) & ~3;
  final bin = Uint8List(binLen)..setRange(0, 36, posBytes);
  if (indexed) bin.setRange(36, 42, idxBytes);

  final node = <String, dynamic>{'mesh': 0};
  if (translation != null) node['translation'] = translation;
  if (scale != 1.0) node['scale'] = [scale, scale, scale];

  final gltf = <String, dynamic>{
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {'nodes': [0]}
    ],
    'nodes': [node],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            if (indexed) 'indices': 1,
          }
        ]
      }
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'count': 3,
        'type': 'VEC3',
        'min': [0, 0, 0],
        'max': [2, 3, 0],
      },
      if (indexed)
        {'bufferView': 1, 'componentType': 5123, 'count': 3, 'type': 'SCALAR'},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': 36, 'target': 34962},
      if (indexed)
        {'buffer': 0, 'byteOffset': 36, 'byteLength': 6, 'target': 34963},
    ],
    'buffers': [
      {'byteLength': binLen}
    ],
    if (draco) 'extensionsRequired': ['KHR_draco_mesh_compression'],
  };

  final jsonBytes = utf8.encode(json.encode(gltf));
  final jsonLen = (jsonBytes.length + 3) & ~3;
  final jsonChunk = Uint8List(jsonLen)..fillRange(0, jsonLen, 0x20);
  jsonChunk.setRange(0, jsonBytes.length, jsonBytes);

  final total = 12 + 8 + jsonLen + 8 + binLen;
  final out = ByteData(total);
  out.setUint32(0, 0x46546C67, Endian.little);
  out.setUint32(4, 2, Endian.little);
  out.setUint32(8, total, Endian.little);
  out.setUint32(12, jsonLen, Endian.little);
  out.setUint32(16, 0x4E4F534A, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(20, 20 + jsonLen, jsonChunk);
  out.setUint32(20 + jsonLen, binLen, Endian.little);
  out.setUint32(20 + jsonLen + 4, 0x004E4942, Endian.little);
  bytes.setRange(20 + jsonLen + 8, 20 + jsonLen + 8 + binLen, bin);
  return bytes;
}

void main() {
  group('GltfParser', () {
    test('parses a GLB triangle into MeshData (counts, bounds, normals)', () {
      final m = GltfParser.parse(_glb());
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
      expect(m.indices32, isNotNull);
      expect(m.bounds.maxX, closeTo(2, 1e-4));
      expect(m.bounds.maxY, closeTo(3, 1e-4));
      // POSITION had no NORMAL → smooth-computed; triangle faces +Z.
      final s = 0 * kFloatsPerVertex;
      expect(m.vertices[s + 5].abs(), closeTo(1.0, 1e-4)); // nz
    });

    test('also routes through ModelParser.parse(format: glb)', () {
      final m = ModelParser.parse(_glb(), format: 'glb');
      expect(m.triangleCount, 1);
    });

    test('applies a node translation to the geometry', () {
      final m = GltfParser.parse(_glb(translation: [10, 5, 0]));
      expect(m.bounds.minX, closeTo(10, 1e-4));
      expect(m.bounds.maxX, closeTo(12, 1e-4));
      expect(m.bounds.maxY, closeTo(8, 1e-4)); // 3 + 5
    });

    test('applies a node scale to the geometry', () {
      final m = GltfParser.parse(_glb(scale: 3.0));
      expect(m.bounds.maxX, closeTo(6, 1e-4)); // 2 * 3
      expect(m.bounds.maxY, closeTo(9, 1e-4)); // 3 * 3
    });

    test('handles a non-indexed primitive', () {
      final m = GltfParser.parse(_glb(indexed: false));
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
    });

    test('rejects Draco-compressed glTF with a clear error', () {
      expect(() => GltfParser.parse(_glb(draco: true)),
          throwsA(isA<ModelParseException>()));
    });
  });
}
