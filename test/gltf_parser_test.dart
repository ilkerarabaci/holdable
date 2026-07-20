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

/// Builds a GLB triangle with TEXCOORD_0 UVs and a material whose base-color
/// texture points at embedded (fake) PNG bytes, exercising the texture path.
Uint8List _texturedGlb() {
  final pos = Float32List.fromList([0, 0, 0, 2, 0, 0, 0, 3, 0]);
  final uv = Float32List.fromList([0, 0, 1, 0, 0, 1]);
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

  // BIN: pos [0,36) | uv [36,60) | png [60,68)
  final bin = Uint8List(68)
    ..setRange(0, 36, pos.buffer.asUint8List())
    ..setRange(36, 60, uv.buffer.asUint8List())
    ..setRange(60, 68, png);

  final gltf = <String, dynamic>{
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {'nodes': [0]}
    ],
    'nodes': [
      {'mesh': 0}
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'TEXCOORD_0': 1},
            'material': 0,
          }
        ]
      }
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorTexture': {'index': 0}
        }
      }
    ],
    'textures': [
      {'source': 0}
    ],
    'images': [
      {'bufferView': 2, 'mimeType': 'image/png'}
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
      {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC2'},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
      {'buffer': 0, 'byteOffset': 36, 'byteLength': 24},
      {'buffer': 0, 'byteOffset': 60, 'byteLength': 8},
    ],
    'buffers': [
      {'byteLength': 68}
    ],
  };

  final jsonBytes = utf8.encode(json.encode(gltf));
  final jsonLen = (jsonBytes.length + 3) & ~3;
  final jsonChunk = Uint8List(jsonLen)..fillRange(0, jsonLen, 0x20);
  jsonChunk.setRange(0, jsonBytes.length, jsonBytes);
  final total = 12 + 8 + jsonLen + 8 + bin.length;
  final out = ByteData(total);
  out.setUint32(0, 0x46546C67, Endian.little);
  out.setUint32(4, 2, Endian.little);
  out.setUint32(8, total, Endian.little);
  out.setUint32(12, jsonLen, Endian.little);
  out.setUint32(16, 0x4E4F534A, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(20, 20 + jsonLen, jsonChunk);
  out.setUint32(20 + jsonLen, bin.length, Endian.little);
  out.setUint32(20 + jsonLen + 4, 0x004E4942, Endian.little);
  bytes.setRange(20 + jsonLen + 8, 20 + jsonLen + 8 + bin.length, bin);
  return bytes;
}

/// Builds a GLB whose one mesh has two primitives sharing the same POSITION
/// accessor (one triangle each, non-indexed), each with its own material and
/// [factors] baseColorFactor — the shape a server-converted multi-material
/// model (e.g. a car) has after the merge, exercising the per-material
/// vertex-color bake.
Uint8List _multiMaterialGlb(List<List<double>> factors) {
  final pos = Float32List.fromList([0, 0, 0, 2, 0, 0, 0, 3, 0]);
  final bin = Uint8List(36)..setRange(0, 36, pos.buffer.asUint8List());

  final gltf = <String, dynamic>{
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {'nodes': [0]}
    ],
    'nodes': [
      {'mesh': 0}
    ],
    'meshes': [
      {
        'primitives': [
          for (var i = 0; i < factors.length; i++)
            {
              'attributes': {'POSITION': 0},
              'material': i,
            }
        ]
      }
    ],
    'materials': [
      for (final f in factors)
        {
          'pbrMetallicRoughness': {'baseColorFactor': f}
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
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': 36, 'target': 34962},
    ],
    'buffers': [
      {'byteLength': 36}
    ],
  };

  final jsonBytes = utf8.encode(json.encode(gltf));
  final jsonLen = (jsonBytes.length + 3) & ~3;
  final jsonChunk = Uint8List(jsonLen)..fillRange(0, jsonLen, 0x20);
  jsonChunk.setRange(0, jsonBytes.length, jsonBytes);
  final total = 12 + 8 + jsonLen + 8 + bin.length;
  final out = ByteData(total);
  out.setUint32(0, 0x46546C67, Endian.little);
  out.setUint32(4, 2, Endian.little);
  out.setUint32(8, total, Endian.little);
  out.setUint32(12, jsonLen, Endian.little);
  out.setUint32(16, 0x4E4F534A, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(20, 20 + jsonLen, jsonChunk);
  out.setUint32(20 + jsonLen, bin.length, Endian.little);
  out.setUint32(20 + jsonLen + 4, 0x004E4942, Endian.little);
  bytes.setRange(20 + jsonLen + 8, 20 + jsonLen + 8 + bin.length, bin);
  return bytes;
}

void main() {
  group('GltfParser', () {
    test('reads TEXCOORD_0 UVs and extracts the base-color texture', () {
      final m = GltfParser.parse(_texturedGlb());
      expect(m.vertexCount, 3);
      // UVs land in the interleaved buffer at floats 6,7.
      expect(m.vertices[1 * kFloatsPerVertex + 6], closeTo(1.0, 1e-6));
      expect(m.vertices[2 * kFloatsPerVertex + 7], closeTo(1.0, 1e-6));
      // The embedded image bytes come back verbatim.
      expect(m.textureBytes, isNotNull);
      expect(m.textureBytes!.length, 8);
      expect(m.textureBytes![0], 0x89);
      expect(m.textureBytes![1], 0x50);
    });

    test('models without TEXCOORD_0 have zero UVs and no texture', () {
      final m = GltfParser.parse(_glb());
      expect(m.textureBytes, isNull);
      expect(m.vertices[0 * kFloatsPerVertex + 6], 0);
      expect(m.vertices[0 * kFloatsPerVertex + 7], 0);
    });
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

    test('bakes per-material baseColorFactor into the vertex color slots', () {
      const red = [0.8, 0.1, 0.2, 1.0];
      const blue = [0.1, 0.2, 0.9, 1.0];
      final m = GltfParser.parse(_multiMaterialGlb([red, blue]));
      expect(m.vertexCount, 6); // two primitives of 3 verts, merged
      expect(m.hasVertexColors, isTrue);
      // First primitive's 3 vertices carry the red factor (LINEAR, unconverted
      // — Filament multiplies the COLOR attribute in linear space)…
      for (var i = 0; i < 3; i++) {
        final s = i * kFloatsPerVertex;
        expect(m.vertices[s + 8], closeTo(0.8, 1e-6)); // r
        expect(m.vertices[s + 9], closeTo(0.1, 1e-6)); // g
        expect(m.vertices[s + 10], closeTo(0.2, 1e-6)); // b
        expect(m.vertices[s + 11], 1.0); // a stays opaque
      }
      // …and the second primitive's 3 vertices the blue factor.
      for (var i = 3; i < 6; i++) {
        final s = i * kFloatsPerVertex;
        expect(m.vertices[s + 8], closeTo(0.1, 1e-6));
        expect(m.vertices[s + 9], closeTo(0.2, 1e-6));
        expect(m.vertices[s + 10], closeTo(0.9, 1e-6));
        expect(m.vertices[s + 11], 1.0);
      }
    });

    test('two materials with the SAME color do not flag hasVertexColors', () {
      const grey = [0.5, 0.5, 0.5, 1.0];
      final m = GltfParser.parse(_multiMaterialGlb([grey, grey]));
      expect(m.hasVertexColors, isFalse);
      // The single color is still baked (harmless — unused without the flag).
      expect(m.vertices[8], closeTo(0.5, 1e-6));
    });

    test('materialless models keep white slots and no vertex-color flag', () {
      final m = GltfParser.parse(_glb());
      expect(m.hasVertexColors, isFalse);
      final s = 0 * kFloatsPerVertex;
      expect(m.vertices[s + 8], 1.0);
      expect(m.vertices[s + 9], 1.0);
      expect(m.vertices[s + 10], 1.0);
      expect(m.vertices[s + 11], 1.0);
    });
  });
}
