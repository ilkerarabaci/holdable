import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/dae_parser.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

/// One Z-up triangle (Z becomes Y after the up-axis conversion).
const _triangleDae = '''
<?xml version="1.0"?>
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
  <asset><up_axis>Z_UP</up_axis></asset>
  <library_geometries>
    <geometry id="g"><mesh>
      <source id="g-pos">
        <float_array id="g-pos-array" count="9">0 0 0 2 0 0 0 0 3</float_array>
        <technique_common>
          <accessor source="#g-pos-array" count="3" stride="3"/>
        </technique_common>
      </source>
      <vertices id="g-verts"><input semantic="POSITION" source="#g-pos"/></vertices>
      <triangles count="1">
        <input semantic="VERTEX" source="#g-verts" offset="0"/>
        <p>0 1 2</p>
      </triangles>
    </mesh></geometry>
  </library_geometries>
</COLLADA>
''';

/// A polylist quad with per-corner positions+normals at different offsets.
const _polylistDae = '''
<COLLADA version="1.4.1">
  <library_geometries>
    <geometry id="q"><mesh>
      <source id="q-pos">
        <float_array id="q-pos-array" count="12">0 0 0 1 0 0 1 1 0 0 1 0</float_array>
      </source>
      <source id="q-norm">
        <float_array id="q-norm-array" count="3">0 0 1</float_array>
      </source>
      <vertices id="q-verts"><input semantic="POSITION" source="#q-pos"/></vertices>
      <polylist count="1">
        <input semantic="VERTEX" source="#q-verts" offset="0"/>
        <input semantic="NORMAL" source="#q-norm" offset="1"/>
        <vcount>4</vcount>
        <p>0 0 1 0 2 0 3 0</p>
      </polylist>
    </mesh></geometry>
  </library_geometries>
</COLLADA>
''';

void main() {
  group('DaeParser', () {
    test('parses a Z_UP triangle and converts to Y-up', () {
      final m = DaeParser.parse(_b(_triangleDae));
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
      // Z-up (0,0,3) → Y-up (0,3,0).
      expect(m.bounds.maxY, closeTo(3, 1e-5));
      expect(m.bounds.maxX, closeTo(2, 1e-5));
    });

    test('parses a polylist quad with authored normals into 2 triangles', () {
      final m = DaeParser.parse(_b(_polylistDae));
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
      // Authored normal +Z survives (no up-axis conversion declared).
      expect(m.vertices[0 * kFloatsPerVertex + 5], closeTo(1, 1e-5));
    });

    test('also routes through ModelParser.parse(format: dae)', () {
      final m = ModelParser.parse(_b(_triangleDae), format: 'dae');
      expect(m.triangleCount, 1);
    });

    test('parses the bundled vase.dae sample', () {
      final bytes = File('assets/sample_models/vase.dae').readAsBytesSync();
      final m = DaeParser.parse(bytes);
      expect(m.triangleCount, greaterThan(500));
      // The vase is taller (Y after Z_UP conversion) than wide.
      expect(m.bounds.sizeY, greaterThan(m.bounds.sizeX));
    });

    test('rejects non-COLLADA and empty input with ModelParseException', () {
      expect(() => DaeParser.parse(_b('<xml>nope</xml>')),
          throwsA(isA<ModelParseException>()));
      expect(() => DaeParser.parse(Uint8List(0)),
          throwsA(isA<ModelParseException>()));
    });
  });
}
