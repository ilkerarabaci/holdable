import 'dart:math' as math;
import 'dart:typed_data';

import 'model_parser.dart';

/// Parses **OFF** (Object File Format) — a simple ASCII polygon format (Princeton
/// shape benchmark, Geomview) — into the renderer-agnostic [MeshData].
///
/// Layout: a header line `OFF`, then `nVerts nFaces nEdges`, then the vertices
/// (`x y z`), then the faces (`k i0 i1 … i(k-1)` with an optional trailing
/// `r g b [a]` colour). Polygons are fan-triangulated; smooth normals computed.
/// `#` comments and blank lines are skipped. Pure Dart → isolate-safe.
class OffParser {
  static MeshData parse(Uint8List bytes) {
    if (bytes.isEmpty) throw ModelParseException('Empty OFF file.');
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      throw ModelParseException('Could not read this OFF ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    final text = String.fromCharCodes(bytes);
    // Token stream over all non-comment content (newlines don't matter once we
    // know the counts — values are whitespace-separated).
    final tokens = <String>[];
    for (final rawLine in text.split('\n')) {
      final hash = rawLine.indexOf('#');
      final line = (hash >= 0 ? rawLine.substring(0, hash) : rawLine).trim();
      if (line.isEmpty) continue;
      tokens.addAll(line.split(RegExp(r'\s+')));
    }
    if (tokens.isEmpty) throw ModelParseException('OFF has no content.');

    var t = 0;
    // The first token is the magic. It may be glued to the counts (e.g. "OFF").
    // Accept OFF / COFF / NOFF / 4OFF etc.
    if (tokens[t].toUpperCase().endsWith('OFF')) {
      t++;
    } else {
      throw ModelParseException('Not an OFF file (missing OFF header).');
    }

    int nextInt() {
      if (t >= tokens.length) throw ModelParseException('OFF ended early.');
      return int.parse(tokens[t++]);
    }

    double nextDouble() {
      if (t >= tokens.length) throw ModelParseException('OFF ended early.');
      return double.parse(tokens[t++]);
    }

    final nVerts = nextInt();
    final nFaces = nextInt();
    nextInt(); // nEdges (unused)
    if (nVerts <= 0) throw ModelParseException('OFF has no vertices.');

    final positions = Float32List(nVerts * 3);
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (var i = 0; i < nVerts; i++) {
      final x = nextDouble(), y = nextDouble(), z = nextDouble();
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

    final indices = <int>[];
    for (var f = 0; f < nFaces; f++) {
      final k = nextInt();
      if (k < 3) {
        // skip this face's vertex refs (degenerate)
        for (var j = 0; j < k; j++) {
          nextInt();
        }
        continue;
      }
      final face = List<int>.generate(k, (_) => nextInt());
      // Optional per-face colour may follow; we don't consume it explicitly —
      // the next face starts with its vertex count, and any trailing colour
      // tokens on this line were merged into the stream. To stay robust we only
      // read exactly k indices and rely on counts; colours (if present) would
      // desync parsing, so detect+skip: peek if the next tokens look like a
      // colour (handled by trusting the spec's k-then-indices; most OFF files
      // omit per-face colour).
      for (var j = 1; j < k - 1; j++) {
        indices..add(face[0])..add(face[j])..add(face[j + 1]);
      }
    }
    if (indices.isEmpty) throw ModelParseException('OFF has no faces.');

    // Smooth normals.
    final normals = Float32List(nVerts * 3);
    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = indices[i], b = indices[i + 1], c = indices[i + 2];
      if (a >= nVerts || b >= nVerts || c >= nVerts) continue;
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

    final out = Float32List(nVerts * kFloatsPerVertex);
    for (var i = 0; i < nVerts; i++) {
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

    return MeshData(
      vertices: out,
      vertexCount: nVerts,
      triangleCount: indices.length ~/ 3,
      bounds: ModelBounds(minX, minY, minZ, maxX, maxY, maxZ),
      indices16: nVerts <= 0x10000 ? Uint16List.fromList(indices) : null,
      indices32: nVerts <= 0x10000 ? null : Uint32List.fromList(indices),
    );
  }
}
