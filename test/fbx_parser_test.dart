import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/fbx_parser.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

/// FBX 7.x ASCII: one quad polygon (terminated by ~index), Y-up.
const _fbx7 = '''
; FBX 7.4.0 project file (ASCII)
GlobalSettings:  {
\tProperties70:  {
\t\tP: "UpAxis", "int", "Integer", "",1
\t}
}
Objects:  {
\tGeometry: 1001, "Geometry::Quad", "Mesh" {
\t\tVertices: *12 {
\t\t\ta: 0,0,0, 2,0,0, 2,3,0, 0,3,0
\t\t}
\t\tPolygonVertexIndex: *4 {
\t\t\ta: 0,1,2,-4
\t\t}
\t}
}
''';

/// FBX 6.x ASCII: bare comma lists, no *N {a:} wrapper, Z-up.
const _fbx6 = '''
FBXHeaderExtension:  {
\tFBXVersion: 6100
}
GlobalSettings:  {
\tProperties60:  {
\t\tProperty: "UpAxis", "int", "",2
\t}
}
Objects:  {
\tModel: "Model::Tri", "Mesh" {
\t\tVertices: 0,0,0, 2,0,0, 0,0,3
\t\tPolygonVertexIndex: 0,1,-3
\t}
}
''';

void main() {
  group('FbxParser', () {
    test('parses 7.x ASCII (array syntax, quad → 2 triangles)', () {
      final m = FbxParser.parse(_b(_fbx7));
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
      expect(m.bounds.maxX, closeTo(2, 1e-5));
      expect(m.bounds.maxY, closeTo(3, 1e-5));
    });

    test('parses 6.x ASCII (bare lists) and converts Z-up to Y-up', () {
      final m = FbxParser.parse(_b(_fbx6));
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
      // Z-up (0,0,3) → Y-up (0,3,0).
      expect(m.bounds.maxY, closeTo(3, 1e-5));
    });

    test('also routes through ModelParser.parse(format: fbx)', () {
      final m = ModelParser.parse(_b(_fbx7), format: 'fbx');
      expect(m.triangleCount, 2);
    });

    test('parses the bundled star.fbx sample', () {
      final bytes = File('assets/sample_models/star.fbx').readAsBytesSync();
      final m = FbxParser.parse(bytes);
      expect(m.vertexCount, 22);
      expect(m.triangleCount, 40);
      // Star extruded along Z in a Z-up file → depth ends up on Y.
      expect(m.bounds.sizeY, closeTo(16, 1e-3));
    });

    test('rejects binary FBX with a clear ASCII-re-export message', () {
      final bin = Uint8List.fromList(
          'Kaydara FBX Binary  \x00\x1a\x00'.codeUnits + List.filled(64, 0));
      expect(
        () => FbxParser.parse(bin),
        throwsA(isA<ModelParseException>().having(
            (e) => e.message, 'message', contains('FBX ASCII'))),
      );
    });

    test('rejects garbage/empty input with ModelParseException', () {
      expect(() => FbxParser.parse(_b('hello world, not an fbx')),
          throwsA(isA<ModelParseException>()));
      expect(() => FbxParser.parse(Uint8List(0)),
          throwsA(isA<ModelParseException>()));
    });
  });
}
