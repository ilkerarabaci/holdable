import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'model_parser.dart';

/// Parses **3MF** (3D Manufacturing Format) — the modern 3D-printing container
/// that's replacing STL — into the renderer-agnostic [MeshData] (so it flows
/// through the whole pipeline: Thermion upload, render modes, CPU thumbnails).
///
/// A .3mf is a ZIP holding an XML model part (`3D/3dmodel.model`) with a `<mesh>`
/// of `<vertices>` and `<triangles>`. We unzip (archive pkg) and parse the mesh
/// attributes directly (no XML dep). Color/material extensions are ignored for
/// now (white surface). Smooth normals are computed. Pure Dart → isolate-safe.
class ThreeMfParser {
  static MeshData parse(Uint8List bytes) {
    if (bytes.isEmpty) throw ModelParseException('Empty 3MF file.');
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      throw ModelParseException('Could not read this 3MF ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? modelFile;
    for (final f in archive) {
      if (f.name.toLowerCase().endsWith('.model')) {
        modelFile = f;
        break;
      }
    }
    if (modelFile == null) {
      throw ModelParseException('3MF has no model part (.model).');
    }
    final xml = String.fromCharCodes(modelFile.content);

    // Vertices: <vertex x=".." y=".." z=".."/> (attribute order isn't assumed).
    final px = <double>[], py = <double>[], pz = <double>[];
    for (final m in RegExp(r'<vertex\b([^>]*?)/?>').allMatches(xml)) {
      final a = m.group(1)!;
      px.add(_attrD(a, 'x'));
      py.add(_attrD(a, 'y'));
      pz.add(_attrD(a, 'z'));
    }
    if (px.isEmpty) throw ModelParseException('3MF mesh has no vertices.');

    // Triangles: <triangle v1=".." v2=".." v3=".."/>.
    final indices = <int>[];
    for (final m in RegExp(r'<triangle\b([^>]*?)/?>').allMatches(xml)) {
      final a = m.group(1)!;
      indices..add(_attrI(a, 'v1'))..add(_attrI(a, 'v2'))..add(_attrI(a, 'v3'));
    }
    if (indices.isEmpty) throw ModelParseException('3MF mesh has no triangles.');

    final vc = px.length;
    final positions = Float32List(vc * 3);
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (var i = 0; i < vc; i++) {
      final x = px[i], y = py[i], z = pz[i];
      positions[i * 3] = x;
      positions[i * 3 + 1] = y;
      positions[i * 3 + 2] = z;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (z < minZ) minZ = z;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
      if (z > maxZ) maxZ = z;
    }

    // Smooth normals (accumulate face normals per shared vertex).
    final normals = Float32List(vc * 3);
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t], b = indices[t + 1], c = indices[t + 2];
      if (a >= vc || b >= vc || c >= vc) continue;
      final ux = positions[b * 3] - positions[a * 3];
      final uy = positions[b * 3 + 1] - positions[a * 3 + 1];
      final uz = positions[b * 3 + 2] - positions[a * 3 + 2];
      final vx = positions[c * 3] - positions[a * 3];
      final vy = positions[c * 3 + 1] - positions[a * 3 + 1];
      final vz = positions[c * 3 + 2] - positions[a * 3 + 2];
      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      for (final idx in [a, b, c]) {
        normals[idx * 3] += nx;
        normals[idx * 3 + 1] += ny;
        normals[idx * 3 + 2] += nz;
      }
    }

    final out = Float32List(vc * kFloatsPerVertex);
    for (var i = 0; i < vc; i++) {
      final s = i * kFloatsPerVertex;
      out[s] = positions[i * 3];
      out[s + 1] = positions[i * 3 + 1];
      out[s + 2] = positions[i * 3 + 2];
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
    }

    final List<int> idx;
    if (vc <= 0x10000) {
      idx = Uint16List.fromList(indices);
    } else {
      idx = Uint32List.fromList(indices);
    }

    return MeshData(
      vertices: out,
      vertexCount: vc,
      triangleCount: indices.length ~/ 3,
      bounds: ModelBounds(minX, minY, minZ, maxX, maxY, maxZ),
      indices16: vc <= 0x10000 ? idx as Uint16List : null,
      indices32: vc <= 0x10000 ? null : idx as Uint32List,
    );
  }

  static double _attrD(String attrs, String name) {
    final m = RegExp('$name\\s*=\\s*"([^"]*)"').firstMatch(attrs);
    if (m == null) throw ModelParseException('3MF vertex missing $name.');
    return double.parse(m.group(1)!);
  }

  static int _attrI(String attrs, String name) {
    final m = RegExp('$name\\s*=\\s*"([^"]*)"').firstMatch(attrs);
    if (m == null) throw ModelParseException('3MF triangle missing $name.');
    return int.parse(m.group(1)!);
  }
}
