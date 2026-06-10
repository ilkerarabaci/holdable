import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model_parser.dart';

/// Parses **COLLADA `.dae`** (XML) into the renderer-agnostic [MeshData].
///
/// Lightweight tag/attribute scanning (same approach as the 3MF parser — no
/// XML dependency) over the parts that carry geometry:
/// `<library_geometries>` → `<geometry>` → `<mesh>` with `<source>` float
/// arrays, `<vertices>` POSITION mapping, and `<triangles>` / `<polylist>` /
/// `<polygons>` index blocks (polygons fan-triangulated). POSITION + NORMAL +
/// TEXCOORD inputs are honored per-corner (vertices deduplicated by their
/// index triple, like the OBJ path); smooth normals are computed when a mesh
/// has none. `<up_axis>` Z_UP / X_UP are converted to the viewer's Y-up.
///
/// Not handled (documented limits): visual-scene node transforms (geometries
/// are merged as-authored), controllers/skinning, animations, materials.
/// Pure Dart → isolate-safe.
class DaeParser {
  static MeshData parse(Uint8List bytes) {
    if (bytes.isEmpty) throw ModelParseException('Empty DAE file.');
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      throw ModelParseException('Could not read this DAE ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.contains('<COLLADA')) {
      throw ModelParseException('Not a COLLADA file (missing <COLLADA> root).');
    }

    final upAxis =
        RegExp(r'<up_axis>\s*([A-Za-z_]+)\s*</up_axis>').firstMatch(text)?.group(1) ??
            'Y_UP';

    // source id → float data (the accessor stride is implied by the semantic
    // that references it: POSITION/NORMAL = 3, TEXCOORD = 2).
    final sources = <String, Float64List>{};
    for (final m in RegExp(r'<source\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)</source>')
        .allMatches(text)) {
      final body = m.group(2)!;
      final fa = RegExp(r'<float_array\b[^>]*>([\s\S]*?)</float_array>')
          .firstMatch(body);
      if (fa == null) continue;
      sources[m.group(1)!] = _doubles(fa.group(1)!);
    }

    // vertices id → POSITION source id.
    final verticesPos = <String, String>{};
    for (final m in RegExp(r'<vertices\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)</vertices>')
        .allMatches(text)) {
      for (final input
          in RegExp(r'<input\b[^>]*/?>').allMatches(m.group(2)!)) {
        final tag = input.group(0)!;
        if (_attr(tag, 'semantic')?.toUpperCase() == 'POSITION') {
          final src = _attr(tag, 'source');
          if (src != null) verticesPos[m.group(1)!] = src.replaceFirst('#', '');
        }
      }
    }

    // Output (deduplicated per pos/normal/uv index triple).
    final outPos = <double>[];
    final outNorm = <double>[];
    final outUv = <double>[];
    final indices = <int>[];
    final keyToIndex = <String, int>{};
    var anyAuthoredNormal = false;

    void addPrimitiveBlock(String tag, String body) {
      // Inputs: offset → (semantic, source floats).
      Float64List? pos, norm, uv;
      var posOff = 0, normOff = -1, uvOff = -1, maxOff = 0;
      for (final input in RegExp(r'<input\b[^>]*/?>').allMatches(body)) {
        final t = input.group(0)!;
        final semantic = _attr(t, 'semantic')?.toUpperCase();
        final srcId = _attr(t, 'source')?.replaceFirst('#', '');
        final off = int.tryParse(_attr(t, 'offset') ?? '0') ?? 0;
        if (off > maxOff) maxOff = off;
        if (srcId == null) continue;
        switch (semantic) {
          case 'VERTEX':
            pos = sources[verticesPos[srcId]];
            posOff = off;
          case 'NORMAL':
            norm = sources[srcId];
            normOff = off;
          case 'TEXCOORD':
            // Keep the first TEXCOORD set only.
            if (uv == null) {
              uv = sources[srcId];
              uvOff = off;
            }
        }
      }
      if (pos == null) return;
      final posData = pos, normData = norm, uvData = uv;
      final stride = maxOff + 1;

      int corner(List<int> tuple) {
        final pi = tuple[posOff];
        final ni = normOff >= 0 ? tuple[normOff] : -1;
        final ti = uvOff >= 0 ? tuple[uvOff] : -1;
        final key = '$pi/$ni/$ti';
        final existing = keyToIndex[key];
        if (existing != null) return existing;
        if (pi < 0 || pi * 3 + 2 >= posData.length) {
          throw ModelParseException('DAE face references invalid vertex $pi.');
        }
        outPos
          ..add(posData[pi * 3])
          ..add(posData[pi * 3 + 1])
          ..add(posData[pi * 3 + 2]);
        if (normData != null && ni >= 0 && ni * 3 + 2 < normData.length) {
          anyAuthoredNormal = true;
          outNorm
            ..add(normData[ni * 3])
            ..add(normData[ni * 3 + 1])
            ..add(normData[ni * 3 + 2]);
        } else {
          outNorm
            ..add(0)
            ..add(0)
            ..add(0);
        }
        if (uvData != null && ti >= 0 && ti * 2 + 1 < uvData.length) {
          outUv
            ..add(uvData[ti * 2])
            ..add(uvData[ti * 2 + 1]);
        } else {
          outUv
            ..add(0)
            ..add(0);
        }
        final idx = (outPos.length ~/ 3) - 1;
        keyToIndex[key] = idx;
        return idx;
      }

      void emitPolygon(List<int> flat, int cornerCount, int from) {
        final cs = <int>[];
        for (var c = 0; c < cornerCount; c++) {
          final base = (from + c) * stride;
          if (base + stride > flat.length) return;
          cs.add(corner(flat.sublist(base, base + stride)));
        }
        for (var i = 1; i + 1 < cs.length; i++) {
          indices
            ..add(cs[0])
            ..add(cs[i])
            ..add(cs[i + 1]);
        }
      }

      final isPolylist = tag.startsWith('<polylist');
      if (isPolylist) {
        final vcountText =
            RegExp(r'<vcount>([\s\S]*?)</vcount>').firstMatch(body)?.group(1);
        final pText = RegExp(r'<p>([\s\S]*?)</p>').firstMatch(body)?.group(1);
        if (vcountText == null || pText == null) return;
        final vcounts = _ints(vcountText);
        final flat = _ints(pText);
        var at = 0;
        for (final k in vcounts) {
          emitPolygon(flat, k, at);
          at += k;
        }
      } else {
        // <triangles> (one <p>, triples) or <polygons> (one <p> per polygon).
        for (final p in RegExp(r'<p>([\s\S]*?)</p>').allMatches(body)) {
          final flat = _ints(p.group(1)!);
          final corners = flat.length ~/ stride;
          if (tag.startsWith('<triangles')) {
            for (var tri = 0; tri + 2 < corners; tri += 3) {
              emitPolygon(flat, 3, tri);
            }
          } else {
            emitPolygon(flat, corners, 0);
          }
        }
      }
    }

    for (final geom in RegExp(r'<geometry\b[^>]*>([\s\S]*?)</geometry>')
        .allMatches(text)) {
      final mesh =
          RegExp(r'<mesh>([\s\S]*?)</mesh>').firstMatch(geom.group(1)!);
      if (mesh == null) continue;
      for (final prim in RegExp(
              r'<(triangles|polylist|polygons)\b[^>]*>([\s\S]*?)</\1>')
          .allMatches(mesh.group(1)!)) {
        addPrimitiveBlock('<${prim.group(1)!}', prim.group(2)!);
      }
    }

    final vertCount = outPos.length ~/ 3;
    if (vertCount == 0 || indices.isEmpty) {
      throw ModelParseException('DAE has no triangle geometry.');
    }

    // Up-axis conversion to Y-up (positions + normals).
    if (upAxis.toUpperCase() == 'Z_UP') {
      _swizzle(outPos, zUp: true);
      _swizzle(outNorm, zUp: true);
    } else if (upAxis.toUpperCase() == 'X_UP') {
      _swizzle(outPos, zUp: false);
      _swizzle(outNorm, zUp: false);
    }

    if (!anyAuthoredNormal) _smoothNormals(outPos, outNorm, indices);

    final out = Float32List(vertCount * kFloatsPerVertex);
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (var i = 0; i < vertCount; i++) {
      final s = i * kFloatsPerVertex;
      final x = outPos[i * 3], y = outPos[i * 3 + 1], z = outPos[i * 3 + 2];
      out[s] = x;
      out[s + 1] = y;
      out[s + 2] = z;
      var nx = outNorm[i * 3], ny = outNorm[i * 3 + 1], nz = outNorm[i * 3 + 2];
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
      out[s + 6] = outUv[i * 2];
      out[s + 7] = outUv[i * 2 + 1];
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

  /// In-place axis conversion: Z_UP (x,y,z)→(x,z,−y); X_UP (x,y,z)→(−y,x,z).
  static void _swizzle(List<double> v, {required bool zUp}) {
    for (var i = 0; i + 2 < v.length; i += 3) {
      final x = v[i], y = v[i + 1], z = v[i + 2];
      if (zUp) {
        v[i] = x;
        v[i + 1] = z;
        v[i + 2] = -y;
      } else {
        v[i] = -y;
        v[i + 1] = x;
        v[i + 2] = z;
      }
    }
  }

  static void _smoothNormals(
      List<double> pos, List<double> norm, List<int> indices) {
    for (var i = 0; i < norm.length; i++) {
      norm[i] = 0;
    }
    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = indices[i], b = indices[i + 1], c = indices[i + 2];
      final ux = pos[b * 3] - pos[a * 3];
      final uy = pos[b * 3 + 1] - pos[a * 3 + 1];
      final uz = pos[b * 3 + 2] - pos[a * 3 + 2];
      final vx = pos[c * 3] - pos[a * 3];
      final vy = pos[c * 3 + 1] - pos[a * 3 + 1];
      final vz = pos[c * 3 + 2] - pos[a * 3 + 2];
      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      for (final v in [a, b, c]) {
        norm[v * 3] += nx;
        norm[v * 3 + 1] += ny;
        norm[v * 3 + 2] += nz;
      }
    }
  }

  /// Value of attribute [name] inside an XML [tag] string, or null.
  static String? _attr(String tag, String name) =>
      RegExp('\\b$name="([^"]*)"').firstMatch(tag)?.group(1);

  static Float64List _doubles(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    final out = Float64List(parts.length);
    var n = 0;
    for (final p in parts) {
      if (p.isEmpty) continue;
      out[n++] = double.parse(p);
    }
    return n == out.length ? out : out.sublist(0, n);
  }

  static List<int> _ints(String s) => [
        for (final p in s.trim().split(RegExp(r'\s+')))
          if (p.isNotEmpty) int.parse(p)
      ];
}
