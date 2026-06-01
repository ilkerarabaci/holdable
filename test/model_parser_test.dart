import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';

/// Reads a bundled sample model straight from disk (assets aren't bundled in
/// unit tests; the test cwd is the package root).
Uint8List _sample(String name) =>
    File('assets/sample_models/$name').readAsBytesSync();

/// Builds a minimal binary STL with the given triangles. Each triangle is
/// nine doubles (v0,v1,v2); the stored normal is left as zero so the parser
/// must recompute it.
Uint8List _binaryStl(List<List<double>> triangles) {
  final size = 84 + triangles.length * 50;
  final bytes = Uint8List(size);
  final data = ByteData.sublistView(bytes);
  data.setUint32(80, triangles.length, Endian.little);
  var offset = 84;
  for (final tri in triangles) {
    // normal = 0,0,0
    offset += 12;
    for (final c in tri) {
      data.setFloat32(offset, c, Endian.little);
      offset += 4;
    }
    offset += 2; // attribute byte count
  }
  return bytes;
}

void main() {
  group('OBJ', () {
    test('cube.obj: indexed, shared verts, 12 tris, unit bounds', () {
      final mesh = ModelParser.parseObj(_sample('cube.obj'));
      expect(mesh.isIndexed, isTrue);
      expect(mesh.vertexCount, 8); // 8 shared corners
      expect(mesh.triangleCount, 12); // 6 quads fan-triangulated
      expect(mesh.indices16, isNotNull);
      expect(mesh.indices16!.length, 36);

      expect(mesh.bounds.minX, -1);
      expect(mesh.bounds.maxX, 1);
      expect(mesh.bounds.longestExtent, 2);

      // Vertex stride is 12 floats; color is opaque white.
      expect(mesh.vertices.length, 8 * kFloatsPerVertex);
      for (var i = 0; i < mesh.vertexCount; i++) {
        expect(mesh.vertices[i * kFloatsPerVertex + 8], 1); // r
        expect(mesh.vertices[i * kFloatsPerVertex + 11], 1); // a
      }
    });

    test('cube.obj: computed normals are unit length', () {
      final mesh = ModelParser.parseObj(_sample('cube.obj'));
      for (var i = 0; i < mesh.vertexCount; i++) {
        final b = i * kFloatsPerVertex;
        final nx = mesh.vertices[b + 3];
        final ny = mesh.vertices[b + 4];
        final nz = mesh.vertices[b + 5];
        final len = (nx * nx + ny * ny + nz * nz);
        expect(len, closeTo(1.0, 1e-5));
      }
    });

    test('negative (relative) indices resolve from the end', () {
      final obj = Uint8List.fromList(
        'v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\n'.codeUnits,
      );
      final mesh = ModelParser.parseObj(obj);
      expect(mesh.vertexCount, 3);
      expect(mesh.triangleCount, 1);
    });
  });

  group('ASCII STL', () {
    test('cube.stl: non-indexed, 12 tris, 36 verts, unit bounds', () {
      final mesh = ModelParser.parseStl(_sample('cube.stl'));
      expect(mesh.isIndexed, isFalse);
      expect(mesh.triangleCount, 12);
      expect(mesh.vertexCount, 36);
      expect(mesh.bounds.minX, -1);
      expect(mesh.bounds.maxX, 1);
    });

    test('other ASCII samples parse with non-zero triangles', () {
      for (final name in const [
        'octahedron.stl',
        'tetrahedron.stl',
        'hex_pendant.stl',
        'icosahedron.stl',
        'lamp_shade.stl',
      ]) {
        final mesh = ModelParser.parseStl(_sample(name));
        expect(mesh.triangleCount, greaterThan(0), reason: name);
        expect(mesh.vertexCount, mesh.triangleCount * 3, reason: name);
      }
    });
  });

  group('binary STL', () {
    test('detected by size formula and parsed non-indexed', () {
      final stl = _binaryStl([
        [0, 0, 0, 1, 0, 0, 0, 1, 0],
      ]);
      final mesh = ModelParser.parseStl(stl);
      expect(mesh.isIndexed, isFalse);
      expect(mesh.triangleCount, 1);
      expect(mesh.vertexCount, 3);
    });

    test('zero stored normal is recomputed from winding', () {
      // Triangle in the XY plane wound CCW -> normal should be +Z.
      final stl = _binaryStl([
        [0, 0, 0, 1, 0, 0, 0, 1, 0],
      ]);
      final mesh = ModelParser.parseStl(stl);
      final b = 0;
      expect(mesh.vertices[b + 3], closeTo(0, 1e-6)); // nx
      expect(mesh.vertices[b + 4], closeTo(0, 1e-6)); // ny
      expect(mesh.vertices[b + 5], closeTo(1, 1e-6)); // nz
    });

    test('binary header starting with "solid" is not misread as ASCII', () {
      final stl = _binaryStl([
        [0, 0, 0, 2, 0, 0, 0, 2, 0],
      ]);
      // Stamp the word "solid" into the header.
      stl.setRange(0, 5, 'solid'.codeUnits);
      final mesh = ModelParser.parseStl(stl);
      expect(mesh.triangleCount, 1);
      expect(mesh.bounds.maxX, 2);
    });
  });

  group('format dispatch', () {
    test('infers format from filename', () {
      final mesh = ModelParser.parse(
        _sample('cube.obj'),
        filename: 'cube.obj',
      );
      expect(mesh.triangleCount, 12);
    });

    test('unsupported format throws', () {
      expect(
        () => ModelParser.parse(Uint8List(0), filename: 'model.gltf'),
        throwsA(isA<ModelParseException>()),
      );
    });
  });
}
