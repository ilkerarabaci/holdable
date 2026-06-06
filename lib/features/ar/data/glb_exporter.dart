import 'dart:convert';
import 'dart:typed_data';

import '../../viewer/data/model_parser.dart';

/// Serializes a parsed [MeshData] into a **binary glTF (.glb)** — the format the
/// AR layer (`ar_flutter_plugin_2` / arsceneview) loads. AR-1 path (ADR-003):
/// on "View in AR", export the current model to a temporary `.glb` and hand its
/// path to the plugin. Pure Dart (typed_data + json) → isolate-safe and
/// unit-testable with plain `dart`.
///
/// Layout: one buffer with POSITION (vec3 f32), NORMAL (vec3 f32) and indices
/// (ushort/uint), one mesh/primitive, a neutral double-sided PBR material so it
/// reads under AR lighting. POSITION carries the required min/max from the AABB.

const int _glbMagic = 0x46546C67; // 'glTF'
const int _chunkJson = 0x4E4F534A; // 'JSON'
const int _chunkBin = 0x004E4942; // 'BIN\0'

const int _f32 = 5126; // FLOAT
const int _u16 = 5123; // UNSIGNED_SHORT
const int _u32 = 5125; // UNSIGNED_INT
const int _arrayBuffer = 34962;
const int _elementArrayBuffer = 34963;

/// Builds `.glb` bytes for [mesh]. [name] labels the node.
Uint8List glbFromMesh(MeshData mesh, {String name = 'model'}) {
  final vc = mesh.vertexCount;
  final src = mesh.vertices; // interleaved [px,py,pz, nx,ny,nz, u,v, r,g,b,a]

  // De-interleave positions + normals into tightly-packed vec3 buffers.
  final positions = Float32List(vc * 3);
  final normals = Float32List(vc * 3);
  for (var i = 0; i < vc; i++) {
    final s = i * kFloatsPerVertex;
    positions[i * 3] = src[s];
    positions[i * 3 + 1] = src[s + 1];
    positions[i * 3 + 2] = src[s + 2];
    normals[i * 3] = src[s + 3];
    normals[i * 3 + 1] = src[s + 4];
    normals[i * 3 + 2] = src[s + 5];
  }

  // Indices: reuse the parser's, or synthesize sequential ones (STL is
  // non-indexed). Narrowest type that fits.
  final List<int> indices;
  final int indexComponentType;
  final int indexStride;
  if (mesh.indices16 != null) {
    indices = mesh.indices16!;
    indexComponentType = _u16;
    indexStride = 2;
  } else if (mesh.indices32 != null) {
    indices = mesh.indices32!;
    indexComponentType = _u32;
    indexStride = 4;
  } else if (vc <= 0x10000) {
    final u = Uint16List(vc);
    for (var i = 0; i < vc; i++) {
      u[i] = i;
    }
    indices = u;
    indexComponentType = _u16;
    indexStride = 2;
  } else {
    final u = Uint32List(vc);
    for (var i = 0; i < vc; i++) {
      u[i] = i;
    }
    indices = u;
    indexComponentType = _u32;
    indexStride = 4;
  }
  final indexCount = indices.length;

  final posBytes = positions.buffer.asUint8List(0, positions.lengthInBytes);
  final normBytes = normals.buffer.asUint8List(0, normals.lengthInBytes);
  final Uint8List idxBytes = indexComponentType == _u16
      ? (indices is Uint16List ? indices : Uint16List.fromList(indices))
          .buffer
          .asUint8List(0, indexCount * 2)
      : (indices is Uint32List ? indices : Uint32List.fromList(indices))
          .buffer
          .asUint8List(0, indexCount * 4);

  // BIN buffer: positions | normals | indices, each region 4-byte aligned.
  final posLen = posBytes.length; // vc*12 — already a multiple of 4
  final normLen = normBytes.length; // vc*12
  final idxOffset = posLen + normLen;
  final idxLen = idxBytes.length;
  final binUnpadded = idxOffset + idxLen;
  final binLen = _align4(binUnpadded);

  final bin = Uint8List(binLen)
    ..setRange(0, posLen, posBytes)
    ..setRange(posLen, posLen + normLen, normBytes)
    ..setRange(idxOffset, idxOffset + idxLen, idxBytes);

  final b = mesh.bounds;
  final gltf = <String, dynamic>{
    'asset': {'version': '2.0', 'generator': 'Holdable'},
    'scene': 0,
    'scenes': [
      {'nodes': [0]}
    ],
    'nodes': [
      {'mesh': 0, 'name': name}
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'NORMAL': 1},
            'indices': 2,
            'material': 0,
          }
        ]
      }
    ],
    'materials': [
      {
        'name': 'surface',
        'doubleSided': true,
        'pbrMetallicRoughness': {
          'baseColorFactor': [0.82, 0.82, 0.86, 1.0],
          'metallicFactor': 0.0,
          'roughnessFactor': 0.75,
        },
      }
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': _f32,
        'count': vc,
        'type': 'VEC3',
        'min': [b.minX, b.minY, b.minZ],
        'max': [b.maxX, b.maxY, b.maxZ],
      },
      {
        'bufferView': 1,
        'componentType': _f32,
        'count': vc,
        'type': 'VEC3',
      },
      {
        'bufferView': 2,
        'componentType': indexComponentType,
        'count': indexCount,
        'type': 'SCALAR',
      },
    ],
    'bufferViews': [
      {
        'buffer': 0,
        'byteOffset': 0,
        'byteLength': posLen,
        'target': _arrayBuffer,
      },
      {
        'buffer': 0,
        'byteOffset': posLen,
        'byteLength': normLen,
        'target': _arrayBuffer,
      },
      {
        'buffer': 0,
        'byteOffset': idxOffset,
        'byteLength': idxLen,
        'target': _elementArrayBuffer,
      },
    ],
    'buffers': [
      {'byteLength': binLen}
    ],
  };

  // JSON chunk, padded to 4 bytes with spaces (per the glTF spec).
  final jsonBytes = utf8.encode(json.encode(gltf));
  final jsonLen = _align4(jsonBytes.length);
  final jsonChunk = Uint8List(jsonLen)..fillRange(0, jsonLen, 0x20);
  jsonChunk.setRange(0, jsonBytes.length, jsonBytes);

  final total = 12 + (8 + jsonLen) + (8 + binLen);
  final out = ByteData(total);
  var o = 0;
  // GLB header.
  out.setUint32(o, _glbMagic, Endian.little);
  out.setUint32(o + 4, 2, Endian.little);
  out.setUint32(o + 8, total, Endian.little);
  o += 12;
  // JSON chunk.
  out.setUint32(o, jsonLen, Endian.little);
  out.setUint32(o + 4, _chunkJson, Endian.little);
  o += 8;
  final bytes = out.buffer.asUint8List();
  bytes.setRange(o, o + jsonLen, jsonChunk);
  o += jsonLen;
  // BIN chunk.
  out.setUint32(o, binLen, Endian.little);
  out.setUint32(o + 4, _chunkBin, Endian.little);
  o += 8;
  bytes.setRange(o, o + binLen, bin);

  return bytes;
}

int _align4(int n) => (n + 3) & ~3;
