import 'dart:math' as math;
import 'dart:typed_data';

import 'gltf_parser.dart';
import 'ply_parser.dart';

/// Parsing of `.obj` / `.stl` / `.glb` / `.gltf` / `.ply` model files into mesh data.
///
/// This layer is deliberately **pure Dart** — it has no dependency on
/// flutter_scene or flutter_gpu — so the heavy parsing logic is unit-testable
/// without a GPU context. The thin adapter that uploads a [MeshData] into a
/// flutter_scene `Geometry` lives in `scene_geometry.dart`.
///
/// The output vertex buffer matches flutter_scene's unskinned vertex layout
/// (`kUnskinnedPerVertexSize == 48` bytes == 12 floats per vertex):
///
///   [ px, py, pz,  nx, ny, nz,  u, v,  r, g, b, a ]
///
/// Vertex colors are always opaque white so the material's `baseColorFactor`
/// drives the rendered color (UnlitMaterial multiplies the two).
const int kFloatsPerVertex = 12;

/// Axis-aligned bounding box of a parsed mesh, used to frame the camera.
class ModelBounds {
  const ModelBounds(
    this.minX,
    this.minY,
    this.minZ,
    this.maxX,
    this.maxY,
    this.maxZ,
  );

  final double minX, minY, minZ, maxX, maxY, maxZ;

  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;
  double get centerZ => (minZ + maxZ) / 2;

  double get sizeX => maxX - minX;
  double get sizeY => maxY - minY;
  double get sizeZ => maxZ - minZ;

  /// Longest edge of the box — a stable basis for camera distance.
  double get longestExtent => math.max(sizeX, math.max(sizeY, sizeZ));
}

/// Raw, GPU-ready mesh data produced by [ModelParser].
class MeshData {
  MeshData({
    required this.vertices,
    required this.vertexCount,
    required this.triangleCount,
    required this.bounds,
    this.indices16,
    this.indices32,
  });

  /// Interleaved vertex buffer, [kFloatsPerVertex] floats per vertex.
  final Float32List vertices;

  /// Number of vertices in [vertices].
  final int vertexCount;

  /// Number of triangles drawn.
  final int triangleCount;

  /// 16-bit index buffer, or null when the mesh is non-indexed or 32-bit.
  final Uint16List? indices16;

  /// 32-bit index buffer, or null when the mesh is non-indexed or 16-bit.
  final Uint32List? indices32;

  /// Axis-aligned bounds for camera framing.
  final ModelBounds bounds;

  bool get isIndexed => indices16 != null || indices32 != null;
}

/// Thrown when a model file can't be parsed.
class ModelParseException implements Exception {
  ModelParseException(this.message);
  final String message;
  @override
  String toString() => 'ModelParseException: $message';
}

/// Parses `.obj` and `.stl` bytes into [MeshData].
class ModelParser {
  /// Parses [bytes] using [format] (`obj` or `stl`, case-insensitive). When
  /// [format] is null it's inferred from [filename]'s extension.
  static MeshData parse(Uint8List bytes, {String? format, String? filename}) {
    final fmt = (format ?? _extensionOf(filename))?.toLowerCase();
    switch (fmt) {
      case 'obj':
        return parseObj(bytes);
      case 'stl':
        return parseStl(bytes);
      case 'glb':
      case 'gltf':
        return GltfParser.parse(bytes);
      case 'ply':
        return PlyParser.parse(bytes);
      default:
        throw ModelParseException(
          'Unsupported format ${fmt ?? '(unknown)'} — '
          'expected obj, stl, glb, gltf or ply',
        );
    }
  }

  static String? _extensionOf(String? filename) {
    if (filename == null) return null;
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return null;
    return filename.substring(dot + 1);
  }

  // ---------------------------------------------------------------------------
  // STL
  // ---------------------------------------------------------------------------

  /// Parses binary or ASCII STL. STL is inherently non-indexed (each triangle
  /// carries its own three vertices), so the result is a non-indexed mesh with
  /// flat per-face normals (recomputed when the file stores a zero normal).
  static MeshData parseStl(Uint8List bytes) {
    return _isBinaryStl(bytes) ? _parseBinaryStl(bytes) : _parseAsciiStl(bytes);
  }

  /// Binary STL detection by the exact size formula `84 + 50 * triangleCount`.
  /// This is robust against binary files whose 80-byte header happens to start
  /// with the ASCII word "solid".
  static bool _isBinaryStl(Uint8List bytes) {
    if (bytes.length < 84) return false;
    final count = ByteData.sublistView(bytes).getUint32(80, Endian.little);
    return bytes.length == 84 + count * 50;
  }

  static MeshData _parseBinaryStl(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final triCount = data.getUint32(80, Endian.little);
    final vertCount = triCount * 3;
    final out = Float32List(vertCount * kFloatsPerVertex);

    final b = _BoundsAccumulator();
    var w = 0;
    var offset = 84;
    for (var t = 0; t < triCount; t++) {
      var nx = data.getFloat32(offset, Endian.little);
      var ny = data.getFloat32(offset + 4, Endian.little);
      var nz = data.getFloat32(offset + 8, Endian.little);
      offset += 12;

      final p = Float32List(9); // three vertices
      for (var i = 0; i < 9; i++) {
        p[i] = data.getFloat32(offset, Endian.little);
        offset += 4;
      }
      offset += 2; // attribute byte count

      if (nx == 0 && ny == 0 && nz == 0) {
        final n = _faceNormal(
          p[0], p[1], p[2],
          p[3], p[4], p[5],
          p[6], p[7], p[8],
        );
        nx = n[0];
        ny = n[1];
        nz = n[2];
      }

      for (var v = 0; v < 3; v++) {
        final px = p[v * 3];
        final py = p[v * 3 + 1];
        final pz = p[v * 3 + 2];
        w = _writeVertex(out, w, px, py, pz, nx, ny, nz);
        b.add(px, py, pz);
      }
    }

    return MeshData(
      vertices: out,
      vertexCount: vertCount,
      triangleCount: triCount,
      bounds: b.build(),
    );
  }

  static MeshData _parseAsciiStl(Uint8List bytes) {
    final text = String.fromCharCodes(bytes);
    // Collect every vertex in facet order; each consecutive triple is a tri.
    final px = <double>[];
    final py = <double>[];
    final pz = <double>[];
    final fnx = <double>[]; // facet normal per emitted vertex's triangle
    final fny = <double>[];
    final fnz = <double>[];

    double curNx = 0, curNy = 0, curNz = 0;
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('facet normal')) {
        final t = line.split(RegExp(r'\s+'));
        // facet normal nx ny nz
        if (t.length >= 5) {
          curNx = _toDouble(t[2]);
          curNy = _toDouble(t[3]);
          curNz = _toDouble(t[4]);
        } else {
          curNx = curNy = curNz = 0;
        }
      } else if (line.startsWith('vertex')) {
        final t = line.split(RegExp(r'\s+'));
        if (t.length >= 4) {
          px.add(_toDouble(t[1]));
          py.add(_toDouble(t[2]));
          pz.add(_toDouble(t[3]));
          fnx.add(curNx);
          fny.add(curNy);
          fnz.add(curNz);
        }
      }
    }

    final vertCount = px.length - (px.length % 3); // ignore any dangling verts
    if (vertCount < 3) {
      throw ModelParseException('ASCII STL has no complete triangles');
    }
    final triCount = vertCount ~/ 3;
    final out = Float32List(vertCount * kFloatsPerVertex);
    final b = _BoundsAccumulator();
    var w = 0;
    for (var t = 0; t < triCount; t++) {
      final i0 = t * 3;
      var nx = fnx[i0], ny = fny[i0], nz = fnz[i0];
      if (nx == 0 && ny == 0 && nz == 0) {
        final n = _faceNormal(
          px[i0], py[i0], pz[i0],
          px[i0 + 1], py[i0 + 1], pz[i0 + 1],
          px[i0 + 2], py[i0 + 2], pz[i0 + 2],
        );
        nx = n[0];
        ny = n[1];
        nz = n[2];
      }
      for (var v = 0; v < 3; v++) {
        final idx = i0 + v;
        w = _writeVertex(out, w, px[idx], py[idx], pz[idx], nx, ny, nz);
        b.add(px[idx], py[idx], pz[idx]);
      }
    }

    return MeshData(
      vertices: out,
      vertexCount: vertCount,
      triangleCount: triCount,
      bounds: b.build(),
    );
  }

  // ---------------------------------------------------------------------------
  // OBJ
  // ---------------------------------------------------------------------------

  /// Parses an OBJ. Produces an indexed mesh, sharing vertices across faces by
  /// the `v/vt/vn` reference triple. Polygon faces are fan-triangulated. When
  /// the file carries no vertex normals, smooth normals are computed by
  /// accumulating face normals onto shared vertices.
  static MeshData parseObj(Uint8List bytes) {
    final text = String.fromCharCodes(bytes);

    final vPos = <double>[]; // x,y,z triples
    final vNorm = <double>[]; // x,y,z triples
    final vUv = <double>[]; // u,v pairs

    // Output vertex attributes (de-duplicated by face-vertex key).
    final outPos = <double>[];
    final outNorm = <double>[];
    final outUv = <double>[];
    final indices = <int>[];
    final keyToIndex = <String, int>{};
    var fileHadNormals = false;

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final t = line.split(RegExp(r'\s+'));
      switch (t[0]) {
        case 'v':
          if (t.length >= 4) {
            vPos
              ..add(_toDouble(t[1]))
              ..add(_toDouble(t[2]))
              ..add(_toDouble(t[3]));
          }
        case 'vn':
          if (t.length >= 4) {
            fileHadNormals = true;
            vNorm
              ..add(_toDouble(t[1]))
              ..add(_toDouble(t[2]))
              ..add(_toDouble(t[3]));
          }
        case 'vt':
          if (t.length >= 3) {
            vUv
              ..add(_toDouble(t[1]))
              ..add(_toDouble(t[2]));
          }
        case 'f':
          final corners = <int>[]; // output indices for this face
          for (var i = 1; i < t.length; i++) {
            corners.add(
              _resolveObjCorner(
                t[i],
                vPos,
                vNorm,
                vUv,
                outPos,
                outNorm,
                outUv,
                keyToIndex,
              ),
            );
          }
          // Fan-triangulate the polygon (corners[0], i, i+1).
          for (var i = 1; i + 1 < corners.length; i++) {
            indices
              ..add(corners[0])
              ..add(corners[i])
              ..add(corners[i + 1]);
          }
      }
    }

    final vertCount = outPos.length ~/ 3;
    if (vertCount == 0 || indices.isEmpty) {
      throw ModelParseException('OBJ has no faces');
    }

    if (!fileHadNormals) {
      _computeSmoothNormals(outPos, outNorm, indices);
    }

    // Build interleaved buffer + bounds.
    final out = Float32List(vertCount * kFloatsPerVertex);
    final b = _BoundsAccumulator();
    var w = 0;
    for (var i = 0; i < vertCount; i++) {
      final px = outPos[i * 3], py = outPos[i * 3 + 1], pz = outPos[i * 3 + 2];
      final nx = outNorm[i * 3], ny = outNorm[i * 3 + 1], nz = outNorm[i * 3 + 2];
      final u = outUv.isEmpty ? 0.0 : outUv[i * 2];
      final v = outUv.isEmpty ? 0.0 : outUv[i * 2 + 1];
      w = _writeVertex(out, w, px, py, pz, nx, ny, nz, u, v);
      b.add(px, py, pz);
    }

    // Choose the smallest index type that fits.
    Uint16List? i16;
    Uint32List? i32;
    if (vertCount <= 0x10000) {
      i16 = Uint16List.fromList(indices);
    } else {
      i32 = Uint32List.fromList(indices);
    }

    return MeshData(
      vertices: out,
      vertexCount: vertCount,
      triangleCount: indices.length ~/ 3,
      bounds: b.build(),
      indices16: i16,
      indices32: i32,
    );
  }

  /// Resolves one `f` corner token (e.g. `3`, `3/1`, `3/1/2`, `3//2`) to an
  /// output vertex index, creating the vertex on first sight.
  static int _resolveObjCorner(
    String token,
    List<double> vPos,
    List<double> vNorm,
    List<double> vUv,
    List<double> outPos,
    List<double> outNorm,
    List<double> outUv,
    Map<String, int> keyToIndex,
  ) {
    final existing = keyToIndex[token];
    if (existing != null) return existing;

    final parts = token.split('/');
    final vi = _objIndex(parts[0], vPos.length ~/ 3);
    final ti = parts.length > 1 && parts[1].isNotEmpty
        ? _objIndex(parts[1], vUv.length ~/ 2)
        : -1;
    final ni = parts.length > 2 && parts[2].isNotEmpty
        ? _objIndex(parts[2], vNorm.length ~/ 3)
        : -1;

    if (vi < 0 || vi * 3 + 2 >= vPos.length) {
      throw ModelParseException('OBJ face references invalid vertex "$token"');
    }
    outPos
      ..add(vPos[vi * 3])
      ..add(vPos[vi * 3 + 1])
      ..add(vPos[vi * 3 + 2]);
    if (ni >= 0 && ni * 3 + 2 < vNorm.length) {
      outNorm
        ..add(vNorm[ni * 3])
        ..add(vNorm[ni * 3 + 1])
        ..add(vNorm[ni * 3 + 2]);
    } else {
      outNorm
        ..add(0)
        ..add(0)
        ..add(0); // filled in by _computeSmoothNormals when absent
    }
    if (ti >= 0 && ti * 2 + 1 < vUv.length) {
      outUv
        ..add(vUv[ti * 2])
        ..add(vUv[ti * 2 + 1]);
    } else {
      outUv
        ..add(0)
        ..add(0);
    }

    final idx = (outPos.length ~/ 3) - 1;
    keyToIndex[token] = idx;
    return idx;
  }

  /// OBJ indices are 1-based; negatives count back from the current end.
  static int _objIndex(String s, int count) {
    final n = int.parse(s);
    return n > 0 ? n - 1 : count + n;
  }

  static void _computeSmoothNormals(
    List<double> pos,
    List<double> norm,
    List<int> indices,
  ) {
    for (var i = 0; i < norm.length; i++) {
      norm[i] = 0;
    }
    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = indices[i], b = indices[i + 1], c = indices[i + 2];
      final n = _faceNormal(
        pos[a * 3], pos[a * 3 + 1], pos[a * 3 + 2],
        pos[b * 3], pos[b * 3 + 1], pos[b * 3 + 2],
        pos[c * 3], pos[c * 3 + 1], pos[c * 3 + 2],
      );
      for (final v in [a, b, c]) {
        norm[v * 3] += n[0];
        norm[v * 3 + 1] += n[1];
        norm[v * 3 + 2] += n[2];
      }
    }
    for (var v = 0; v * 3 + 2 < norm.length; v++) {
      final x = norm[v * 3], y = norm[v * 3 + 1], z = norm[v * 3 + 2];
      final len = math.sqrt(x * x + y * y + z * z);
      if (len > 1e-12) {
        norm[v * 3] = x / len;
        norm[v * 3 + 1] = y / len;
        norm[v * 3 + 2] = z / len;
      } else {
        norm[v * 3] = 0;
        norm[v * 3 + 1] = 0;
        norm[v * 3 + 2] = 1;
      }
    }
  }

  /// Normalized cross product of (v1-v0) x (v2-v0). Falls back to +Z for
  /// degenerate triangles.
  static List<double> _faceNormal(
    double ax, double ay, double az,
    double bx, double by, double bz,
    double cx, double cy, double cz,
  ) {
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    final nx = uy * vz - uz * vy;
    final ny = uz * vx - ux * vz;
    final nz = ux * vy - uy * vx;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len <= 1e-12) return const [0.0, 0.0, 1.0];
    return [nx / len, ny / len, nz / len];
  }

  /// Writes one 12-float vertex at float-offset [w]; returns the next offset.
  static int _writeVertex(
    Float32List out,
    int w,
    double px, double py, double pz,
    double nx, double ny, double nz, [
    double u = 0,
    double v = 0,
  ]) {
    out[w] = px;
    out[w + 1] = py;
    out[w + 2] = pz;
    out[w + 3] = nx;
    out[w + 4] = ny;
    out[w + 5] = nz;
    out[w + 6] = u;
    out[w + 7] = v;
    out[w + 8] = 1; // r
    out[w + 9] = 1; // g
    out[w + 10] = 1; // b
    out[w + 11] = 1; // a
    return w + kFloatsPerVertex;
  }

  static double _toDouble(String s) => double.parse(s);
}

class _BoundsAccumulator {
  double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  double maxX = -double.infinity,
      maxY = -double.infinity,
      maxZ = -double.infinity;

  void add(double x, double y, double z) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }

  ModelBounds build() {
    if (minX > maxX) {
      return const ModelBounds(0, 0, 0, 0, 0, 0);
    }
    return ModelBounds(minX, minY, minZ, maxX, maxY, maxZ);
  }
}
