import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model_parser.dart';

/// Parses **FBX ASCII** into the renderer-agnostic [MeshData].
///
/// FBX comes in two encodings. The proprietary **binary** container (magic
/// `Kaydara FBX Binary`, with zlib-compressed typed arrays) is NOT supported —
/// it is rejected with a clear message suggesting an ASCII re-export (every
/// major DCC tool offers "FBX ASCII" on export). The **ASCII** form is parsed
/// here: every `Geometry`/`Model` node's `Vertices:` (control points) +
/// `PolygonVertexIndex:` (polygons, negative value = ~lastIndex terminator)
/// pair is read and fan-triangulated, supporting both FBX 7.x array syntax
/// (`Vertices: *24 { a: … }`) and the older 6.x bare-list syntax. Geometries
/// are merged. `UpAxis: 2` (Z-up) is converted to the viewer's Y-up. Smooth
/// normals are computed; layered normals/UVs and node transforms are ignored
/// (documented limits — fallback UVs cover texturing). Pure Dart → isolate-safe.
class FbxParser {
  static const _binaryMagic = 'Kaydara FBX Binary';

  static MeshData parse(Uint8List bytes) {
    if (bytes.isEmpty) throw ModelParseException('Empty FBX file.');
    if (bytes.length >= _binaryMagic.length &&
        String.fromCharCodes(bytes.sublist(0, _binaryMagic.length)) ==
            _binaryMagic) {
      throw ModelParseException(
          'Binary FBX is not supported yet — re-export as "FBX ASCII" '
          '(available in Blender/Maya/3ds Max export settings).');
    }
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      throw ModelParseException('Could not read this FBX ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);

    // Up axis: GlobalSettings → P: "UpAxis", "int", "Integer", "",2 (2 = Z-up).
    // FBX 6.x writes Property: "UpAxis", "int", "",2.
    var zUp = false;
    final up = RegExp(r'"UpAxis"[^\n)]*?,\s*(-?\d+)\s*[\n)]').firstMatch(text);
    if (up != null) zUp = up.group(1) == '2';

    final positions = <double>[];
    final indices = <int>[];

    // Every Vertices: block, each paired with the next PolygonVertexIndex:.
    var searchFrom = 0;
    while (true) {
      final vAt = text.indexOf('Vertices:', searchFrom);
      if (vAt < 0) break;
      final pAt = text.indexOf('PolygonVertexIndex:', vAt);
      if (pAt < 0) break;
      final verts = _numbers(text, vAt + 'Vertices:'.length);
      final poly = _numbers(text, pAt + 'PolygonVertexIndex:'.length);
      searchFrom = pAt + 'PolygonVertexIndex:'.length;
      if (verts.length < 9 || poly.isEmpty) continue;

      final base = positions.length ~/ 3;
      final vCount = verts.length ~/ 3;
      for (var i = 0; i < vCount * 3; i += 3) {
        final x = verts[i], y = verts[i + 1], z = verts[i + 2];
        if (zUp) {
          positions
            ..add(x)
            ..add(z)
            ..add(-y);
        } else {
          positions
            ..add(x)
            ..add(y)
            ..add(z);
        }
      }

      // Polygons: indices accumulate until a negative value, which is the
      // XOR-complemented (~i) final corner.
      final corners = <int>[];
      for (final raw in poly) {
        final v = raw.toInt();
        final last = v < 0;
        final idx = last ? ~v : v;
        if (idx < 0 || idx >= vCount) {
          throw ModelParseException('FBX polygon references invalid vertex $idx.');
        }
        corners.add(base + idx);
        if (last) {
          for (var i = 1; i + 1 < corners.length; i++) {
            indices
              ..add(corners[0])
              ..add(corners[i])
              ..add(corners[i + 1]);
          }
          corners.clear();
        }
      }
    }

    final vertCount = positions.length ~/ 3;
    if (vertCount == 0 || indices.isEmpty) {
      throw ModelParseException(
          'FBX has no readable geometry (no Vertices/PolygonVertexIndex).');
    }

    // Smooth normals (authored LayerElementNormal is by-polygon-vertex and is
    // intentionally ignored — see class doc).
    final normals = Float64List(vertCount * 3);
    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = indices[i], b = indices[i + 1], c = indices[i + 2];
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
      hadAuthoredNormals: false,
      vertices: out,
      vertexCount: vertCount,
      triangleCount: indices.length ~/ 3,
      bounds: ModelBounds(minX, minY, minZ, maxX, maxY, maxZ),
      indices16: vertCount <= 0x10000 ? Uint16List.fromList(indices) : null,
      indices32: vertCount <= 0x10000 ? null : Uint32List.fromList(indices),
    );
  }

  /// Reads the number list that follows an FBX property keyword at [from].
  /// Accepts the 7.x array form `*N { a: 1,2,3 }` and the 6.x bare form
  /// `1,2,3` (numbers may span lines); stops at the first token that can't be
  /// part of the list.
  static List<double> _numbers(String text, int from) {
    var i = from;
    // Skip whitespace, then an optional "*N" and "{ a:" wrapper.
    void skipWs() {
      while (i < text.length &&
          (text[i] == ' ' ||
              text[i] == '\t' ||
              text[i] == '\n' ||
              text[i] == '\r')) {
        i++;
      }
    }

    skipWs();
    if (i < text.length && text[i] == '*') {
      i++;
      while (i < text.length && _isDigit(text.codeUnitAt(i))) {
        i++;
      }
      skipWs();
      if (i < text.length && text[i] == '{') i++;
      skipWs();
      if (i + 1 < text.length && text[i] == 'a' && text[i + 1] == ':') i += 2;
    }

    final out = <double>[];
    final sb = StringBuffer();
    void flush() {
      if (sb.isEmpty) return;
      final v = double.tryParse(sb.toString());
      if (v != null) out.add(v);
      sb.clear();
    }

    while (i < text.length) {
      final ch = text[i];
      final cu = text.codeUnitAt(i);
      if (_isDigit(cu) ||
          ch == '-' ||
          ch == '+' ||
          ch == '.' ||
          ch == 'e' ||
          ch == 'E') {
        sb.write(ch);
      } else if (ch == ',' ||
          ch == ' ' ||
          ch == '\t' ||
          ch == '\n' ||
          ch == '\r') {
        flush();
      } else {
        break; // '}' or the next keyword
      }
      i++;
    }
    flush();
    return out;
  }

  static bool _isDigit(int cu) => cu >= 0x30 && cu <= 0x39;
}
