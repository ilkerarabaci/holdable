import 'dart:math' as math;
import 'dart:typed_data';

import 'model_parser.dart';

/// Parses **3D Studio `.3ds`** (binary chunk format) into the renderer-agnostic
/// [MeshData].
///
/// Walks the classic chunk tree: `0x4D4D` main → `0x3D3D` editor → `0x4000`
/// named object → `0x4100` triangle mesh → `0x4110` vertices, `0x4120` faces,
/// `0x4140` per-vertex UVs. Multiple objects are merged. 3DS is Z-up; geometry
/// is converted to the viewer's Y-up. Smooth normals are computed (3DS stores
/// none). Materials, the `0x4160` local axis (pivot) and keyframer chunks are
/// ignored — vertices are stored in mesh space, which is what other casual
/// viewers show too. Pure Dart → isolate-safe.
class ThreeDsParser {
  static const int _mainChunk = 0x4D4D;
  static const int _editorChunk = 0x3D3D;
  static const int _objectChunk = 0x4000;
  static const int _meshChunk = 0x4100;
  static const int _vertsChunk = 0x4110;
  static const int _facesChunk = 0x4120;
  static const int _uvsChunk = 0x4140;

  static MeshData parse(Uint8List bytes) {
    if (bytes.length < 6) throw ModelParseException('Empty/truncated 3DS file.');
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      throw ModelParseException('Could not read this 3DS ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint16(0, Endian.little) != _mainChunk) {
      throw ModelParseException('Not a 3DS file (missing 0x4D4D main chunk).');
    }
    final mainLen = math.min(bd.getUint32(2, Endian.little), bytes.length);

    // Merged output (positions per object are appended with an index offset).
    final positions = <double>[];
    final uvs = <double>[];
    final indices = <int>[];

    void parseMesh(int start, int end) {
      var at = start;
      var vertBase = positions.length ~/ 3;
      // Per-mesh UVs are aligned to its vertex array; pad if absent.
      var meshVerts = 0;
      var sawUvs = false;
      while (at + 6 <= end) {
        final id = bd.getUint16(at, Endian.little);
        final len = bd.getUint32(at + 2, Endian.little);
        if (len < 6 || at + len > end) break;
        final body = at + 6;
        switch (id) {
          case _vertsChunk:
            final count = bd.getUint16(body, Endian.little);
            var o = body + 2;
            for (var i = 0; i < count; i++) {
              final x = bd.getFloat32(o, Endian.little);
              final y = bd.getFloat32(o + 4, Endian.little);
              final z = bd.getFloat32(o + 8, Endian.little);
              // Z-up → Y-up.
              positions
                ..add(x)
                ..add(z)
                ..add(-y);
              o += 12;
            }
            meshVerts = count;
          case _facesChunk:
            final count = bd.getUint16(body, Endian.little);
            var o = body + 2;
            for (var i = 0; i < count; i++) {
              indices
                ..add(vertBase + bd.getUint16(o, Endian.little))
                ..add(vertBase + bd.getUint16(o + 2, Endian.little))
                ..add(vertBase + bd.getUint16(o + 4, Endian.little));
              o += 8; // 3 indices + face flags
            }
          case _uvsChunk:
            final count = bd.getUint16(body, Endian.little);
            var o = body + 2;
            for (var i = 0; i < count; i++) {
              uvs
                ..add(bd.getFloat32(o, Endian.little))
                ..add(bd.getFloat32(o + 4, Endian.little));
              o += 8;
            }
            sawUvs = true;
        }
        at += len;
      }
      if (!sawUvs && meshVerts > 0) {
        uvs.addAll(List.filled(meshVerts * 2, 0.0));
      }
    }

    void walk(int start, int end, int depth) {
      var at = start;
      while (at + 6 <= end) {
        final id = bd.getUint16(at, Endian.little);
        final len = bd.getUint32(at + 2, Endian.little);
        if (len < 6 || at + len > end) break;
        switch (id) {
          case _editorChunk:
            walk(at + 6, at + len, depth + 1);
          case _objectChunk:
            // Object name is a NUL-terminated string, then child chunks.
            var o = at + 6;
            while (o < at + len && bytes[o] != 0) {
              o++;
            }
            o++; // skip NUL
            // Children of the object (usually one 0x4100 trimesh).
            var c = o;
            while (c + 6 <= at + len) {
              final cid = bd.getUint16(c, Endian.little);
              final clen = bd.getUint32(c + 2, Endian.little);
              if (clen < 6 || c + clen > at + len) break;
              if (cid == _meshChunk) parseMesh(c + 6, c + clen);
              c += clen;
            }
        }
        at += len;
      }
    }

    walk(6, mainLen, 0);

    final vertCount = positions.length ~/ 3;
    if (vertCount == 0 || indices.isEmpty) {
      throw ModelParseException('3DS has no triangle geometry.');
    }

    // Smooth normals (3DS files carry only smoothing groups, not normals).
    final normals = Float64List(vertCount * 3);
    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = indices[i], b = indices[i + 1], c = indices[i + 2];
      if (a >= vertCount || b >= vertCount || c >= vertCount) continue;
      final ux = positions[b * 3] - positions[a * 3];
      final uy = positions[b * 3 + 1] - positions[a * 3 + 1];
      final uz = positions[b * 3 + 2] - positions[a * 3 + 2];
      final vx = positions[c * 3] - positions[a * 3];
      final vy = positions[c * 3 + 1] - positions[a * 3 + 1];
      final vz = positions[c * 3 + 2] - positions[a * 3 + 2];
      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      for (final v in [a, b, c]) {
        normals[v * 3] += nx;
        normals[v * 3 + 1] += ny;
        normals[v * 3 + 2] += nz;
      }
    }

    final out = Float32List(vertCount * kFloatsPerVertex);
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (var i = 0; i < vertCount; i++) {
      final s = i * kFloatsPerVertex;
      final x = positions[i * 3], y = positions[i * 3 + 1], z = positions[i * 3 + 2];
      out[s] = x;
      out[s + 1] = y;
      out[s + 2] = z;
      var nx = normals[i * 3], ny = normals[i * 3 + 1], nz = normals[i * 3 + 2];
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-12) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        nz = 1.0;
      }
      out[s + 3] = nx;
      out[s + 4] = ny;
      out[s + 5] = nz;
      if (i * 2 + 1 < uvs.length) {
        out[s + 6] = uvs[i * 2];
        out[s + 7] = uvs[i * 2 + 1];
      }
      out[s + 8] = 1.0;
      out[s + 9] = 1.0;
      out[s + 10] = 1.0;
      out[s + 11] = 1.0;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (z < minZ) minZ = z;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
      if (z > maxZ) maxZ = z;
    }

    return MeshData(
      vertices: out,
      vertexCount: vertCount,
      triangleCount: indices.length ~/ 3,
      bounds: ModelBounds(minX, minY, minZ, maxX, maxY, maxZ),
      indices16: vertCount <= 0x10000 ? Uint16List.fromList(indices) : null,
      indices32: vertCount <= 0x10000 ? null : Uint32List.fromList(indices),
    );
  }
}
