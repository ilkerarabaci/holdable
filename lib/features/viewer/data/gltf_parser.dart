import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model_parser.dart';

/// Parses **glTF 2.0 / GLB** into the renderer-agnostic [MeshData] (the same
/// interleaved buffer obj/stl produce), so glTF models flow through the exact
/// same pipeline — Thermion upload, render modes, CPU thumbnails, info stats.
/// Pure Dart (dart:convert + typed_data + math; a tiny internal 4×4 matrix) so
/// it runs in the parse isolate and is unit-testable with plain `dart`.
///
/// Supported: GLB container and `.gltf` JSON with an embedded base64 `data:`
/// buffer; scene/node hierarchy with TRS or matrix transforms; multiple
/// meshes/primitives (merged); POSITION (+ NORMAL, else smooth-computed);
/// TEXCOORD_0 (float or normalized ubyte/ushort); USHORT/UINT/UBYTE or
/// non-indexed triangles. The base-color texture of the *largest* primitive
/// (by triangle count) is extracted as encoded PNG/JPEG bytes so the viewer
/// can show a textured model (e.g. a car with its livery); since primitives
/// are merged into one mesh, other primitives' textures are dropped.
/// Unsupported (clear error): Draco/meshopt compression, external `.bin`,
/// non-triangles.
class GltfParser {
  static const int _glbMagic = 0x46546C67; // 'glTF'
  static const int _chunkJson = 0x4E4F534A; // 'JSON'
  static const int _chunkBin = 0x004E4942; // 'BIN\0'

  static MeshData parse(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ModelParseException('Empty glTF/GLB file.');
    }
    try {
      return _parse(bytes);
    } on ModelParseException {
      rethrow;
    } catch (e) {
      // A malformed file surfaces a clean error, not a raw FormatException/etc.
      throw ModelParseException('Could not read this glTF/GLB ($e).');
    }
  }

  static MeshData _parse(Uint8List bytes) {
    final (Map<String, dynamic> gltf, Uint8List? glbBin) = _readContainer(bytes);
    final buffers = _resolveBuffers(gltf, glbBin);

    final accessors = (gltf['accessors'] as List?) ?? const [];
    final bufferViews = (gltf['bufferViews'] as List?) ?? const [];
    final meshes = (gltf['meshes'] as List?) ?? const [];
    final nodes = (gltf['nodes'] as List?) ?? const [];

    final required = gltf['extensionsRequired'];
    if (required is List &&
        required.any((e) =>
            e.toString().contains('draco') ||
            e.toString().contains('meshopt'))) {
      throw ModelParseException(
          'This glTF uses mesh compression (Draco/meshopt) — not supported yet.');
    }

    ByteData bdFor(int bufferIndex) => ByteData.sublistView(buffers[bufferIndex]);

    List<double> readVec3(int accessorIndex) {
      final acc = accessors[accessorIndex] as Map<String, dynamic>;
      final bv = bufferViews[acc['bufferView'] as int] as Map<String, dynamic>;
      final bd = bdFor(bv['buffer'] as int);
      final base =
          (bv['byteOffset'] as int? ?? 0) + (acc['byteOffset'] as int? ?? 0);
      final stride = bv['byteStride'] as int? ?? 12; // vec3 f32 tightly packed
      final count = acc['count'] as int;
      final out = Float64List(count * 3);
      for (var i = 0; i < count; i++) {
        final o = base + i * stride;
        out[i * 3] = bd.getFloat32(o, Endian.little);
        out[i * 3 + 1] = bd.getFloat32(o + 4, Endian.little);
        out[i * 3 + 2] = bd.getFloat32(o + 8, Endian.little);
      }
      return out;
    }

    // TEXCOORD accessor: float, or normalized ubyte/ushort (glTF 2.0 §3.6.2.2).
    List<double> readVec2(int accessorIndex) {
      final acc = accessors[accessorIndex] as Map<String, dynamic>;
      final bv = bufferViews[acc['bufferView'] as int] as Map<String, dynamic>;
      final bd = bdFor(bv['buffer'] as int);
      final base =
          (bv['byteOffset'] as int? ?? 0) + (acc['byteOffset'] as int? ?? 0);
      final ct = acc['componentType'] as int? ?? 5126;
      final compSize = ct == 5121 ? 1 : (ct == 5123 ? 2 : 4);
      final stride = bv['byteStride'] as int? ?? compSize * 2;
      final count = acc['count'] as int;
      final out = Float64List(count * 2);
      for (var i = 0; i < count; i++) {
        final o = base + i * stride;
        switch (ct) {
          case 5121: // normalized ubyte
            out[i * 2] = bd.getUint8(o) / 255.0;
            out[i * 2 + 1] = bd.getUint8(o + 1) / 255.0;
          case 5123: // normalized ushort
            out[i * 2] = bd.getUint16(o, Endian.little) / 65535.0;
            out[i * 2 + 1] = bd.getUint16(o + 2, Endian.little) / 65535.0;
          default: // float
            out[i * 2] = bd.getFloat32(o, Endian.little);
            out[i * 2 + 1] = bd.getFloat32(o + 4, Endian.little);
        }
      }
      return out;
    }

    List<int> readIndices(int accessorIndex) {
      final acc = accessors[accessorIndex] as Map<String, dynamic>;
      final bv = bufferViews[acc['bufferView'] as int] as Map<String, dynamic>;
      final bd = bdFor(bv['buffer'] as int);
      final base =
          (bv['byteOffset'] as int? ?? 0) + (acc['byteOffset'] as int? ?? 0);
      final ct = acc['componentType'] as int; // 5121 ubyte,5123 ushort,5125 uint
      final size = ct == 5121 ? 1 : (ct == 5123 ? 2 : 4);
      final stride = bv['byteStride'] as int? ?? size;
      final count = acc['count'] as int;
      final out = List<int>.filled(count, 0);
      for (var i = 0; i < count; i++) {
        final o = base + i * stride;
        out[i] = switch (ct) {
          5121 => bd.getUint8(o),
          5123 => bd.getUint16(o, Endian.little),
          _ => bd.getUint32(o, Endian.little),
        };
      }
      return out;
    }

    final verts = <double>[]; // interleaved 12-float
    final indices = <int>[];
    var vertexOffset = 0;
    var anyComputedNormals = false;
    final b = _BoundsAccumulator();
    final materials = (gltf['materials'] as List?) ?? const [];
    final textures = (gltf['textures'] as List?) ?? const [];
    final images = (gltf['images'] as List?) ?? const [];
    int? firstColorArgb;
    // Base-color texture of the largest primitive (by triangle count) — the
    // best single texture to show on the merged mesh (e.g. a car body livery).
    Uint8List? textureBytes;
    var textureOwnerTris = -1;

    // Encoded PNG/JPEG bytes of a material's base-color texture, if present.
    Uint8List? extractBaseColorImage(int materialIndex) {
      if (materialIndex < 0 || materialIndex >= materials.length) return null;
      final pbr = (materials[materialIndex] as Map<String, dynamic>?)?[
          'pbrMetallicRoughness'] as Map<String, dynamic>?;
      final texInfo = pbr?['baseColorTexture'] as Map<String, dynamic>?;
      final texIndex = texInfo?['index'] as int?;
      if (texIndex == null || texIndex < 0 || texIndex >= textures.length) {
        return null;
      }
      final source =
          (textures[texIndex] as Map<String, dynamic>)['source'] as int?;
      if (source == null || source < 0 || source >= images.length) return null;
      final image = images[source] as Map<String, dynamic>;
      final uri = image['uri'] as String?;
      if (uri != null && uri.startsWith('data:')) {
        return base64.decode(uri.substring(uri.indexOf(',') + 1));
      }
      final bvIndex = image['bufferView'] as int?;
      if (bvIndex == null) return null;
      final bv = bufferViews[bvIndex] as Map<String, dynamic>;
      final buf = buffers[bv['buffer'] as int];
      final off = bv['byteOffset'] as int? ?? 0;
      final len = bv['byteLength'] as int;
      return Uint8List.sublistView(buf, off, off + len);
    }

    void addPrimitive(Map<String, dynamic> prim, Float64List world) {
      final mode = prim['mode'] as int? ?? 4;
      if (mode != 4) return; // TRIANGLES only
      // Capture the first primitive's material colour so the viewer can show the
      // model in its own colour (e.g. a red car). glTF baseColorFactor is LINEAR;
      // convert to sRGB so the viewer's sRGB→linear path reproduces it.
      if (firstColorArgb == null && prim['material'] is int) {
        final mi = prim['material'] as int;
        if (mi >= 0 && mi < materials.length) {
          final pbr = (materials[mi] as Map<String, dynamic>?)?[
              'pbrMetallicRoughness'] as Map<String, dynamic>?;
          final bcf = pbr?['baseColorFactor'];
          if (bcf is List && bcf.length >= 3) {
            int ch(num v) =>
                (_linearToSrgb(v.toDouble().clamp(0.0, 1.0)) * 255).round();
            firstColorArgb = (0xFF << 24) |
                (ch(bcf[0]) << 16) |
                (ch(bcf[1]) << 8) |
                ch(bcf[2]);
          }
        }
      }
      final attrs = prim['attributes'] as Map<String, dynamic>?;
      if (attrs == null || attrs['POSITION'] == null) return;
      final positions = readVec3(attrs['POSITION'] as int);
      final vCount = positions.length ~/ 3;

      final List<int> localIdx = prim['indices'] != null
          ? readIndices(prim['indices'] as int)
          : List<int>.generate(vCount, (i) => i);

      // Keep the base-color texture of the biggest primitive seen so far.
      final primTris = localIdx.length ~/ 3;
      if (prim['material'] is int && primTris > textureOwnerTris) {
        final img = extractBaseColorImage(prim['material'] as int);
        if (img != null) {
          textureBytes = img;
          textureOwnerTris = primTris;
        }
      }

      // UVs (TEXCOORD_0) — kept as-authored so the texture maps correctly.
      Float64List? uvs;
      if (attrs['TEXCOORD_0'] != null) {
        final raw = readVec2(attrs['TEXCOORD_0'] as int);
        if (raw.length >= vCount * 2) {
          uvs = raw is Float64List ? raw : Float64List.fromList(raw);
        }
      }

      // World-space positions.
      final wpos = Float64List(vCount * 3);
      for (var i = 0; i < vCount; i++) {
        final p = _transformPoint(
            world, positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
        wpos[i * 3] = p[0];
        wpos[i * 3 + 1] = p[1];
        wpos[i * 3 + 2] = p[2];
        b.add(p[0], p[1], p[2]);
      }

      // Normals: rotate provided ones, else smooth-compute from faces.
      Float64List normals;
      if (attrs['NORMAL'] != null) {
        final src = readVec3(attrs['NORMAL'] as int);
        normals = Float64List(vCount * 3);
        for (var i = 0; i < vCount; i++) {
          final d = _transformDir(
              world, src[i * 3], src[i * 3 + 1], src[i * 3 + 2]);
          final len = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
          final inv = len > 1e-12 ? 1.0 / len : 0.0;
          normals[i * 3] = d[0] * inv;
          normals[i * 3 + 1] = d[1] * inv;
          normals[i * 3 + 2] = (len > 1e-12) ? d[2] * inv : 1.0;
        }
      } else {
        normals = _smoothNormals(wpos, localIdx, vCount);
        anyComputedNormals = true;
      }

      for (var i = 0; i < vCount; i++) {
        verts
          ..add(wpos[i * 3])
          ..add(wpos[i * 3 + 1])
          ..add(wpos[i * 3 + 2])
          ..add(normals[i * 3])
          ..add(normals[i * 3 + 1])
          ..add(normals[i * 3 + 2])
          ..add(uvs != null ? uvs[i * 2] : 0) // u
          ..add(uvs != null ? uvs[i * 2 + 1] : 0) // v
          ..add(1) // r
          ..add(1) // g
          ..add(1) // b
          ..add(1); // a
      }
      for (final idx in localIdx) {
        indices.add(idx + vertexOffset);
      }
      vertexOffset += vCount;
    }

    void visit(int nodeIndex, Float64List parent) {
      final node = nodes[nodeIndex] as Map<String, dynamic>;
      final world = _multiply(parent, _localMatrix(node));
      if (node['mesh'] != null) {
        final mesh = meshes[node['mesh'] as int] as Map<String, dynamic>;
        for (final p in (mesh['primitives'] as List)) {
          addPrimitive(p as Map<String, dynamic>, world);
        }
      }
      for (final c in (node['children'] as List? ?? const [])) {
        visit(c as int, world);
      }
    }

    final sceneIndex = gltf['scene'] as int? ?? 0;
    final scenes = gltf['scenes'] as List?;
    final rootNodes = (scenes != null && scenes.isNotEmpty)
        ? ((scenes[sceneIndex] as Map<String, dynamic>)['nodes'] as List? ??
            const [])
        : List<int>.generate(nodes.length, (i) => i);
    for (final n in rootNodes) {
      visit(n as int, _identity());
    }

    if (vertexOffset == 0) {
      throw ModelParseException('glTF has no triangle geometry to render.');
    }

    return MeshData(
      vertices: Float32List.fromList(verts),
      vertexCount: vertexOffset,
      triangleCount: indices.length ~/ 3,
      bounds: b.build(),
      indices32: Uint32List.fromList(indices),
      baseColorArgb: firstColorArgb,
      textureBytes: textureBytes,
      hadAuthoredNormals: !anyComputedNormals,
    );
  }

  // GLB / .gltf container → (json, binChunk?).
  static (Map<String, dynamic>, Uint8List?) _readContainer(Uint8List bytes) {
    if (bytes.length >= 12) {
      final bd = ByteData.sublistView(bytes);
      if (bd.getUint32(0, Endian.little) == _glbMagic) {
        final jsonLen = bd.getUint32(12, Endian.little);
        if (bd.getUint32(16, Endian.little) != _chunkJson) {
          throw ModelParseException('Malformed GLB: missing JSON chunk.');
        }
        final jsonStr = utf8.decode(bytes.sublist(20, 20 + jsonLen));
        Uint8List? bin;
        final binChunkStart = 20 + jsonLen;
        if (bytes.length >= binChunkStart + 8) {
          final binLen = bd.getUint32(binChunkStart, Endian.little);
          if (bd.getUint32(binChunkStart + 4, Endian.little) == _chunkBin) {
            bin = bytes.sublist(binChunkStart + 8, binChunkStart + 8 + binLen);
          }
        }
        return (json.decode(jsonStr) as Map<String, dynamic>, bin);
      }
    }
    // Assume a text .gltf.
    return (json.decode(utf8.decode(bytes)) as Map<String, dynamic>, null);
  }

  static List<Uint8List> _resolveBuffers(
      Map<String, dynamic> gltf, Uint8List? glbBin) {
    final list = (gltf['buffers'] as List?) ?? const [];
    return [
      for (final raw in list)
        () {
          final buf = raw as Map<String, dynamic>;
          final uri = buf['uri'] as String?;
          if (uri == null) {
            if (glbBin == null) {
              throw ModelParseException('glTF buffer has no data (no GLB BIN).');
            }
            return glbBin;
          }
          if (uri.startsWith('data:')) {
            return base64.decode(uri.substring(uri.indexOf(',') + 1));
          }
          throw ModelParseException(
              'External .bin / textures are not supported — use a self-contained .glb.');
        }()
    ];
  }

  // ---- tiny column-major 4×4 matrix math (glTF convention) -----------------

  static Float64List _identity() {
    final m = Float64List(16);
    m[0] = m[5] = m[10] = m[15] = 1.0;
    return m;
  }

  static Float64List _multiply(Float64List a, Float64List b) {
    final r = Float64List(16);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[k * 4 + row] * b[col * 4 + k];
        }
        r[col * 4 + row] = sum;
      }
    }
    return r;
  }

  static List<double> _transformPoint(Float64List m, double x, double y, double z) =>
      [
        m[0] * x + m[4] * y + m[8] * z + m[12],
        m[1] * x + m[5] * y + m[9] * z + m[13],
        m[2] * x + m[6] * y + m[10] * z + m[14],
      ];

  static List<double> _transformDir(Float64List m, double x, double y, double z) =>
      [
        m[0] * x + m[4] * y + m[8] * z,
        m[1] * x + m[5] * y + m[9] * z,
        m[2] * x + m[6] * y + m[10] * z,
      ];

  // Node local transform: explicit matrix (column-major) or TRS.
  static Float64List _localMatrix(Map<String, dynamic> node) {
    final m = node['matrix'] as List?;
    if (m != null && m.length == 16) {
      return Float64List.fromList([for (final v in m) (v as num).toDouble()]);
    }
    final t = node['translation'] as List?;
    final r = node['rotation'] as List?;
    final s = node['scale'] as List?;
    final tx = t != null ? (t[0] as num).toDouble() : 0.0;
    final ty = t != null ? (t[1] as num).toDouble() : 0.0;
    final tz = t != null ? (t[2] as num).toDouble() : 0.0;
    final qx = r != null ? (r[0] as num).toDouble() : 0.0;
    final qy = r != null ? (r[1] as num).toDouble() : 0.0;
    final qz = r != null ? (r[2] as num).toDouble() : 0.0;
    final qw = r != null ? (r[3] as num).toDouble() : 1.0;
    final sx = s != null ? (s[0] as num).toDouble() : 1.0;
    final sy = s != null ? (s[1] as num).toDouble() : 1.0;
    final sz = s != null ? (s[2] as num).toDouble() : 1.0;

    // Column-major M = T * R * S (rotation from the quaternion, scaled columns).
    final out = Float64List(16);
    out[0] = (1 - 2 * (qy * qy + qz * qz)) * sx;
    out[1] = (2 * (qx * qy + qz * qw)) * sx;
    out[2] = (2 * (qx * qz - qy * qw)) * sx;
    out[4] = (2 * (qx * qy - qz * qw)) * sy;
    out[5] = (1 - 2 * (qx * qx + qz * qz)) * sy;
    out[6] = (2 * (qy * qz + qx * qw)) * sy;
    out[8] = (2 * (qx * qz + qy * qw)) * sz;
    out[9] = (2 * (qy * qz - qx * qw)) * sz;
    out[10] = (1 - 2 * (qx * qx + qy * qy)) * sz;
    out[12] = tx;
    out[13] = ty;
    out[14] = tz;
    out[15] = 1.0;
    return out;
  }

  /// Linear → sRGB (glTF colours are linear; the viewer stores an sRGB colour
  /// and converts back to linear when applying it).
  static double _linearToSrgb(double c) =>
      c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;

  static Float64List _smoothNormals(
      Float64List positions, List<int> indices, int vCount) {
    final n = Float64List(vCount * 3);
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t], b = indices[t + 1], c = indices[t + 2];
      final ux = positions[b * 3] - positions[a * 3];
      final uy = positions[b * 3 + 1] - positions[a * 3 + 1];
      final uz = positions[b * 3 + 2] - positions[a * 3 + 2];
      final vx = positions[c * 3] - positions[a * 3];
      final vy = positions[c * 3 + 1] - positions[a * 3 + 1];
      final vz = positions[c * 3 + 2] - positions[a * 3 + 2];
      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      for (final vi in [a, b, c]) {
        n[vi * 3] += nx;
        n[vi * 3 + 1] += ny;
        n[vi * 3 + 2] += nz;
      }
    }
    for (var i = 0; i < vCount; i++) {
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
}

/// Local AABB accumulator (mirrors model_parser's, kept private here).
class _BoundsAccumulator {
  double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  double maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;

  void add(double x, double y, double z) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }

  ModelBounds build() => ModelBounds(minX, minY, minZ, maxX, maxY, maxZ);
}
