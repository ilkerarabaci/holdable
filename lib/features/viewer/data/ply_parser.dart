import 'dart:math' as math;
import 'dart:typed_data';

import 'model_parser.dart';

/// Parses the **Stanford PLY** (Polygon File Format) — a common output of 3D
/// scanners and mesh tools — into the renderer-agnostic [MeshData] that obj/stl
/// produce, so it flows through the entire existing pipeline (Thermion upload,
/// render modes, CPU thumbnails, info stats). Pure Dart → isolate-safe and
/// unit-testable with plain `dart`.
///
/// Supports ASCII and binary (little- and big-endian) bodies, the usual vertex
/// properties (x/y/z, optional nx/ny/nz, optional red/green/blue[/alpha],
/// optional s/t or u/v), and a face list property of any polygon size
/// (fan-triangulated). Per-element property *order* is honored. Normals are
/// smooth-computed when the file doesn't store them.
class PlyParser {
  static MeshData parse(Uint8List bytes) {
    if (bytes.isEmpty) throw ModelParseException('Empty PLY file.');
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      throw ModelParseException('Could not read this PLY ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    // --- Header (always ASCII, terminated by a line "end_header"). ---
    final headerEnd = _findHeaderEnd(bytes);
    if (headerEnd < 0) {
      throw ModelParseException('Not a PLY file (no end_header).');
    }
    final headerText = String.fromCharCodes(bytes.sublist(0, headerEnd));
    final lines = headerText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty || lines.first != 'ply') {
      throw ModelParseException('Not a PLY file.');
    }

    _PlyFormat? format;
    final elements = <_PlyElement>[];
    for (final line in lines.skip(1)) {
      final t = line.split(RegExp(r'\s+'));
      switch (t[0]) {
        case 'format':
          format = switch (t[1]) {
            'ascii' => _PlyFormat.ascii,
            'binary_little_endian' => _PlyFormat.binaryLE,
            'binary_big_endian' => _PlyFormat.binaryBE,
            _ => throw ModelParseException('Unknown PLY format ${t[1]}'),
          };
        case 'element':
          elements.add(_PlyElement(t[1], int.parse(t[2])));
        case 'property':
          if (elements.isEmpty) continue;
          final e = elements.last;
          if (t[1] == 'list') {
            // property list <countType> <indexType> <name>
            e.listProperty = _ListProperty(
              _scalarType(t[2]),
              _scalarType(t[3]),
              t[4],
            );
          } else {
            e.properties.add(_Property(_scalarType(t[1]), t[2]));
          }
        case 'comment':
        case 'obj_info':
          break;
      }
    }
    if (format == null) throw ModelParseException('PLY has no format line.');

    final vertexEl = elements.firstWhere(
      (e) => e.name == 'vertex',
      orElse: () => throw ModelParseException('PLY has no vertex element.'),
    );
    final faceEl =
        elements.where((e) => e.name == 'face' || e.name == 'tristrips').firstOrNull;

    // --- Body. ---
    final reader = format == _PlyFormat.ascii
        ? _AsciiReader(bytes, headerEnd)
        : _BinaryReader(bytes, headerEnd, format == _PlyFormat.binaryLE);

    // Read every element in declared order; keep vertex + face data.
    final vc = vertexEl.count;
    final positions = Float32List(vc * 3);
    final hasNormalsIdx = _propIndices(vertexEl, ['nx', 'ny', 'nz']);
    final hasColorIdx =
        _propIndices(vertexEl, ['red', 'green', 'blue']) ??
            _propIndices(vertexEl, ['r', 'g', 'b']);
    final normals = hasNormalsIdx != null ? Float32List(vc * 3) : null;
    final colors = hasColorIdx != null ? Float32List(vc * 3) : null;
    final colorIsByte = hasColorIdx != null &&
        _isByteType(vertexEl.properties[hasColorIdx[0]].type);
    final xIdx = _propIndex(vertexEl, 'x');
    final yIdx = _propIndex(vertexEl, 'y');
    final zIdx = _propIndex(vertexEl, 'z');
    if (xIdx < 0 || yIdx < 0 || zIdx < 0) {
      throw ModelParseException('PLY vertex is missing x/y/z.');
    }

    final indices = <int>[];

    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (final el in elements) {
      if (el == vertexEl) {
        final n = el.properties.length;
        final row = Float64List(n);
        for (var i = 0; i < vc; i++) {
          for (var p = 0; p < n; p++) {
            row[p] = reader.readScalar(el.properties[p].type);
          }
          final px = row[xIdx], py = row[yIdx], pz = row[zIdx];
          positions[i * 3] = px;
          positions[i * 3 + 1] = py;
          positions[i * 3 + 2] = pz;
          if (px < minX) minX = px;
          if (py < minY) minY = py;
          if (pz < minZ) minZ = pz;
          if (px > maxX) maxX = px;
          if (py > maxY) maxY = py;
          if (pz > maxZ) maxZ = pz;
          if (normals != null && hasNormalsIdx != null) {
            normals[i * 3] = row[hasNormalsIdx[0]];
            normals[i * 3 + 1] = row[hasNormalsIdx[1]];
            normals[i * 3 + 2] = row[hasNormalsIdx[2]];
          }
          if (colors != null && hasColorIdx != null) {
            final s = colorIsByte ? 1.0 / 255.0 : 1.0;
            colors[i * 3] = row[hasColorIdx[0]] * s;
            colors[i * 3 + 1] = row[hasColorIdx[1]] * s;
            colors[i * 3 + 2] = row[hasColorIdx[2]] * s;
          }
        }
      } else if (el == faceEl && el.listProperty != null) {
        for (var f = 0; f < el.count; f++) {
          final count = reader.readScalar(el.listProperty!.countType).toInt();
          final poly = List<int>.generate(
              count, (_) => reader.readScalar(el.listProperty!.indexType).toInt());
          // Fan-triangulate the polygon.
          for (var k = 1; k + 1 < count; k++) {
            indices..add(poly[0])..add(poly[k])..add(poly[k + 1]);
          }
        }
      } else {
        // Skip an unused element's rows.
        for (var i = 0; i < el.count; i++) {
          for (final p in el.properties) {
            reader.readScalar(p.type);
          }
          if (el.listProperty != null) {
            final c = reader.readScalar(el.listProperty!.countType).toInt();
            for (var k = 0; k < c; k++) {
              reader.readScalar(el.listProperty!.indexType);
            }
          }
        }
      }
    }

    if (indices.isEmpty) {
      throw ModelParseException('PLY has no faces to render.');
    }

    // Smooth normals when the file didn't carry them.
    final Float32List outNormals;
    if (normals != null) {
      outNormals = normals;
    } else {
      outNormals = _computeSmoothNormals(positions, indices, vc);
    }

    // Build the interleaved [pos3, normal3, uv2, color4] buffer + index buffer.
    final out = Float32List(vc * kFloatsPerVertex);
    for (var i = 0; i < vc; i++) {
      final s = i * kFloatsPerVertex;
      out[s] = positions[i * 3];
      out[s + 1] = positions[i * 3 + 1];
      out[s + 2] = positions[i * 3 + 2];
      out[s + 3] = outNormals[i * 3];
      out[s + 4] = outNormals[i * 3 + 1];
      out[s + 5] = outNormals[i * 3 + 2];
      // uv (s+6,s+7) left 0.
      out[s + 8] = colors != null ? colors[i * 3] : 1.0;
      out[s + 9] = colors != null ? colors[i * 3 + 1] : 1.0;
      out[s + 10] = colors != null ? colors[i * 3 + 2] : 1.0;
      out[s + 11] = 1.0;
    }

    final triCount = indices.length ~/ 3;
    final Uint16List? i16;
    final Uint32List? i32;
    if (vc <= 0x10000) {
      i16 = Uint16List.fromList(indices);
      i32 = null;
    } else {
      i16 = null;
      i32 = Uint32List.fromList(indices);
    }

    return MeshData(
      hadAuthoredNormals: hasNormalsIdx != null,
      vertices: out,
      vertexCount: vc,
      triangleCount: triCount,
      bounds: ModelBounds(minX, minY, minZ, maxX, maxY, maxZ),
      indices16: i16,
      indices32: i32,
    );
  }

  // --- helpers ---

  static int _findHeaderEnd(Uint8List bytes) {
    // Locate the byte right after the "end_header\n" line.
    const marker = 'end_header';
    final limit = math.min(bytes.length, 1 << 16);
    for (var i = 0; i + marker.length <= limit; i++) {
      var match = true;
      for (var j = 0; j < marker.length; j++) {
        if (bytes[i + j] != marker.codeUnitAt(j)) {
          match = false;
          break;
        }
      }
      if (match) {
        var k = i + marker.length;
        // Consume the trailing CR?/LF.
        if (k < bytes.length && bytes[k] == 0x0D) k++;
        if (k < bytes.length && bytes[k] == 0x0A) k++;
        return k;
      }
    }
    return -1;
  }

  static int _propIndex(_PlyElement el, String name) {
    for (var i = 0; i < el.properties.length; i++) {
      if (el.properties[i].name == name) return i;
    }
    return -1;
  }

  static List<int>? _propIndices(_PlyElement el, List<String> names) {
    final out = <int>[];
    for (final n in names) {
      final i = _propIndex(el, n);
      if (i < 0) return null;
      out.add(i);
    }
    return out;
  }

  static bool _isByteType(_Scalar t) =>
      t == _Scalar.uint8 || t == _Scalar.int8;

  static Float32List _computeSmoothNormals(
      Float32List positions, List<int> indices, int vc) {
    final n = Float32List(vc * 3);
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t], b = indices[t + 1], c = indices[t + 2];
      final ax = positions[a * 3], ay = positions[a * 3 + 1], az = positions[a * 3 + 2];
      final bx = positions[b * 3], by = positions[b * 3 + 1], bz = positions[b * 3 + 2];
      final cx = positions[c * 3], cy = positions[c * 3 + 1], cz = positions[c * 3 + 2];
      final ux = bx - ax, uy = by - ay, uz = bz - az;
      final vx = cx - ax, vy = cy - ay, vz = cz - az;
      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      for (final idx in [a, b, c]) {
        n[idx * 3] += nx;
        n[idx * 3 + 1] += ny;
        n[idx * 3 + 2] += nz;
      }
    }
    for (var i = 0; i < vc; i++) {
      final x = n[i * 3], y = n[i * 3 + 1], z = n[i * 3 + 2];
      final len = math.sqrt(x * x + y * y + z * z);
      if (len > 1e-12) {
        n[i * 3] = x / len;
        n[i * 3 + 1] = y / len;
        n[i * 3 + 2] = z / len;
      } else {
        n[i * 3 + 2] = 1.0;
      }
    }
    return n;
  }

  static _Scalar _scalarType(String s) => switch (s) {
        'char' || 'int8' => _Scalar.int8,
        'uchar' || 'uint8' => _Scalar.uint8,
        'short' || 'int16' => _Scalar.int16,
        'ushort' || 'uint16' => _Scalar.uint16,
        'int' || 'int32' => _Scalar.int32,
        'uint' || 'uint32' => _Scalar.uint32,
        'float' || 'float32' => _Scalar.float32,
        'double' || 'float64' => _Scalar.float64,
        _ => throw ModelParseException('Unknown PLY type $s'),
      };
}

enum _PlyFormat { ascii, binaryLE, binaryBE }

enum _Scalar { int8, uint8, int16, uint16, int32, uint32, float32, float64 }

class _Property {
  _Property(this.type, this.name);
  final _Scalar type;
  final String name;
}

class _ListProperty {
  _ListProperty(this.countType, this.indexType, this.name);
  final _Scalar countType;
  final _Scalar indexType;
  final String name;
}

class _PlyElement {
  _PlyElement(this.name, this.count);
  final String name;
  final int count;
  final List<_Property> properties = [];
  _ListProperty? listProperty;
}

abstract class _Reader {
  double readScalar(_Scalar type);
}

class _AsciiReader implements _Reader {
  _AsciiReader(Uint8List bytes, int offset)
      : _tokens = String.fromCharCodes(bytes.sublist(offset))
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList();
  final List<String> _tokens;
  int _i = 0;

  @override
  double readScalar(_Scalar type) {
    if (_i >= _tokens.length) {
      throw ModelParseException('PLY body ended early.');
    }
    return double.parse(_tokens[_i++]);
  }
}

class _BinaryReader implements _Reader {
  _BinaryReader(Uint8List bytes, this._offset, bool littleEndian)
      : _data = ByteData.sublistView(bytes),
        _endian = littleEndian ? Endian.little : Endian.big;
  final ByteData _data;
  final Endian _endian;
  int _offset;

  @override
  double readScalar(_Scalar type) {
    final double v;
    switch (type) {
      case _Scalar.int8:
        v = _data.getInt8(_offset).toDouble();
        _offset += 1;
      case _Scalar.uint8:
        v = _data.getUint8(_offset).toDouble();
        _offset += 1;
      case _Scalar.int16:
        v = _data.getInt16(_offset, _endian).toDouble();
        _offset += 2;
      case _Scalar.uint16:
        v = _data.getUint16(_offset, _endian).toDouble();
        _offset += 2;
      case _Scalar.int32:
        v = _data.getInt32(_offset, _endian).toDouble();
        _offset += 4;
      case _Scalar.uint32:
        v = _data.getUint32(_offset, _endian).toDouble();
        _offset += 4;
      case _Scalar.float32:
        v = _data.getFloat32(_offset, _endian);
        _offset += 4;
      case _Scalar.float64:
        v = _data.getFloat64(_offset, _endian);
        _offset += 8;
    }
    return v;
  }
}
