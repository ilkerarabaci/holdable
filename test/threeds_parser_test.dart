import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';
import 'package:holdable/features/viewer/data/threeds_parser.dart';

/// Builds a minimal binary 3DS: main → editor → object("T") → mesh with the
/// given vertices (x,y,z triples, 3DS Z-up space) and faces.
Uint8List _threeDs(List<double> verts, List<int> faces, {List<double>? uvs}) {
  final nVerts = verts.length ~/ 3;
  final nFaces = faces.length ~/ 3;
  final vertsLen = 8 + nVerts * 12;
  final facesLen = 8 + nFaces * 8;
  final uvsLen = uvs != null ? 8 + (uvs.length ~/ 2) * 8 : 0;
  final meshLen = 6 + vertsLen + facesLen + uvsLen;
  final objLen = 6 + 2 + meshLen; // name "T\0"
  final editLen = 6 + objLen;
  final mainLen = 6 + editLen;
  final out = ByteData(mainLen);
  var o = 0;
  void chunk(int id, int len) {
    out.setUint16(o, id, Endian.little);
    out.setUint32(o + 2, len, Endian.little);
    o += 6;
  }

  chunk(0x4D4D, mainLen);
  chunk(0x3D3D, editLen);
  chunk(0x4000, objLen);
  out.setUint8(o++, 0x54); // 'T'
  out.setUint8(o++, 0);
  chunk(0x4100, meshLen);
  chunk(0x4110, vertsLen);
  out.setUint16(o, nVerts, Endian.little);
  o += 2;
  for (final v in verts) {
    out.setFloat32(o, v, Endian.little);
    o += 4;
  }
  chunk(0x4120, facesLen);
  out.setUint16(o, nFaces, Endian.little);
  o += 2;
  for (var f = 0; f < nFaces; f++) {
    out.setUint16(o, faces[f * 3], Endian.little);
    out.setUint16(o + 2, faces[f * 3 + 1], Endian.little);
    out.setUint16(o + 4, faces[f * 3 + 2], Endian.little);
    out.setUint16(o + 6, 7, Endian.little);
    o += 8;
  }
  if (uvs != null) {
    chunk(0x4140, uvsLen);
    out.setUint16(o, uvs.length ~/ 2, Endian.little);
    o += 2;
    for (final v in uvs) {
      out.setFloat32(o, v, Endian.little);
      o += 4;
    }
  }
  return out.buffer.asUint8List();
}

void main() {
  group('ThreeDsParser', () {
    test('parses a triangle and converts Z-up to Y-up', () {
      // 3DS-space (0,0,3) (Z up) → viewer (0,3,0).
      final m = ThreeDsParser.parse(
          _threeDs([0, 0, 0, 2, 0, 0, 0, 0, 3], [0, 1, 2]));
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
      expect(m.bounds.maxY, closeTo(3, 1e-5));
      expect(m.bounds.maxX, closeTo(2, 1e-5));
    });

    test('reads per-vertex UVs from the 0x4140 chunk', () {
      final m = ThreeDsParser.parse(_threeDs(
        [0, 0, 0, 1, 0, 0, 0, 1, 0],
        [0, 1, 2],
        uvs: [0, 0, 1, 0, 0, 1],
      ));
      expect(m.vertices[1 * kFloatsPerVertex + 6], closeTo(1, 1e-6)); // u
      expect(m.vertices[2 * kFloatsPerVertex + 7], closeTo(1, 1e-6)); // v
    });

    test('also routes through ModelParser.parse(format: 3ds)', () {
      final m = ModelParser.parse(
          _threeDs([0, 0, 0, 1, 0, 0, 0, 1, 0], [0, 1, 2]),
          format: '3ds');
      expect(m.triangleCount, 1);
    });

    test('parses the bundled gem.3ds sample', () {
      final bytes = File('assets/sample_models/gem.3ds').readAsBytesSync();
      final m = ThreeDsParser.parse(bytes);
      expect(m.vertexCount, 34);
      expect(m.triangleCount, 64);
    });

    test('rejects non-3DS and empty input with ModelParseException', () {
      expect(() => ThreeDsParser.parse(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7])),
          throwsA(isA<ModelParseException>()));
      expect(() => ThreeDsParser.parse(Uint8List(0)),
          throwsA(isA<ModelParseException>()));
    });
  });
}
