import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';
import 'package:holdable/features/viewer/data/ply_parser.dart';

/// A 4-vertex ASCII PLY square (one quad face → 2 triangles), with per-vertex
/// colors, to exercise property order + fan-triangulation + colors.
const _asciiSquare = '''ply
format ascii 1.0
comment test
element vertex 4
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
element face 1
property list uchar int vertex_indices
end_header
0 0 0 255 0 0
2 0 0 0 255 0
2 2 0 0 0 255
0 2 0 255 255 255
4 0 1 2 3
''';

/// The same square as binary little-endian (positions only).
Uint8List _binarySquare() {
  const header = 'ply\n'
      'format binary_little_endian 1.0\n'
      'element vertex 4\n'
      'property float x\nproperty float y\nproperty float z\n'
      'element face 2\n'
      'property list uchar int vertex_indices\n'
      'end_header\n';
  final verts = [
    [0.0, 0.0, 0.0],
    [2.0, 0.0, 0.0],
    [2.0, 2.0, 0.0],
    [0.0, 2.0, 0.0],
  ];
  final faces = [
    [0, 1, 2],
    [0, 2, 3],
  ];
  final bb = BytesBuilder()..add(header.codeUnits);
  final vb = ByteData(verts.length * 12);
  for (var i = 0; i < verts.length; i++) {
    vb.setFloat32(i * 12, verts[i][0], Endian.little);
    vb.setFloat32(i * 12 + 4, verts[i][1], Endian.little);
    vb.setFloat32(i * 12 + 8, verts[i][2], Endian.little);
  }
  bb.add(vb.buffer.asUint8List());
  for (final f in faces) {
    final fb = ByteData(1 + 12)..setUint8(0, 3);
    fb.setInt32(1, f[0], Endian.little);
    fb.setInt32(5, f[1], Endian.little);
    fb.setInt32(9, f[2], Endian.little);
    bb.add(fb.buffer.asUint8List());
  }
  return bb.toBytes();
}

void main() {
  group('PlyParser', () {
    test('ASCII: 4 verts, quad fan-triangulated to 2 tris, bounds, colors', () {
      final m = PlyParser.parse(Uint8List.fromList(_asciiSquare.codeUnits));
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2); // quad → 2 triangles
      expect(m.bounds.maxX, 2);
      expect(m.bounds.maxY, 2);
      // First vertex red: color channels in the interleaved buffer (offset 8-10).
      expect(m.vertices[8], closeTo(1.0, 0.01)); // r
      expect(m.vertices[9], closeTo(0.0, 0.01)); // g
    });

    test('routes through ModelParser.parse(format: ply)', () {
      final m = ModelParser.parse(
          Uint8List.fromList(_asciiSquare.codeUnits), format: 'ply');
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
    });

    test('binary little-endian parses to the same counts', () {
      final m = PlyParser.parse(_binarySquare());
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
      expect(m.bounds.maxX, 2);
    });

    test('computes smooth normals when absent (flat square → +Z)', () {
      final m = PlyParser.parse(_binarySquare());
      // All face normals point +Z for a z=0 square.
      final nz = m.vertices[5]; // first vertex normal z
      expect(nz.abs(), closeTo(1.0, 0.01));
    });

    test('empty / non-PLY input throws ModelParseException', () {
      expect(() => PlyParser.parse(Uint8List(0)),
          throwsA(isA<ModelParseException>()));
      expect(() => PlyParser.parse(Uint8List.fromList('not a ply'.codeUnits)),
          throwsA(isA<ModelParseException>()));
    });
  });
}
