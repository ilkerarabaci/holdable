import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';
import 'package:holdable/features/viewer/data/threemf_parser.dart';

/// Zips a 3MF model XML into a `.3mf` (ZIP) like a real one.
Uint8List _make3mf(String modelXml) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('3D/3dmodel.model', modelXml));
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

const _oneTri = '''<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter">
 <resources>
  <object id="1" type="model">
   <mesh>
    <vertices>
     <vertex x="0" y="0" z="0"/>
     <vertex x="2" y="0" z="0"/>
     <vertex x="0" y="3" z="0"/>
    </vertices>
    <triangles>
     <triangle v1="0" v2="1" v3="2"/>
    </triangles>
   </mesh>
  </object>
 </resources>
 <build><item objectid="1"/></build>
</model>''';

void main() {
  group('ThreeMfParser', () {
    test('parses a zipped 3MF mesh into MeshData (counts + bounds)', () {
      final m = ThreeMfParser.parse(_make3mf(_oneTri));
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
      expect(m.bounds.maxX, 2);
      expect(m.bounds.maxY, 3);
      // Flat triangle in z=0 → normal ±Z.
      expect(m.vertices[5].abs(), closeTo(1.0, 0.01));
    });

    test('routes through ModelParser.parse for 3mf and threemf', () {
      final bytes = _make3mf(_oneTri);
      expect(ModelParser.parse(bytes, format: '3mf').triangleCount, 1);
      expect(ModelParser.parse(bytes, format: 'threemf').triangleCount, 1);
    });

    test('attribute order is not assumed (z before x before y)', () {
      const reordered = '''<model><resources><object id="1"><mesh>
        <vertices>
         <vertex z="0" x="0" y="0"/>
         <vertex y="0" z="0" x="4"/>
         <vertex x="0" y="5" z="0"/>
        </vertices>
        <triangles><triangle v3="2" v1="0" v2="1"/></triangles>
       </mesh></object></resources></model>''';
      final m = ThreeMfParser.parse(_make3mf(reordered));
      expect(m.vertexCount, 3);
      expect(m.bounds.maxX, 4);
      expect(m.bounds.maxY, 5);
    });

    test('empty / non-zip input throws ModelParseException', () {
      expect(() => ThreeMfParser.parse(Uint8List(0)),
          throwsA(isA<ModelParseException>()));
      expect(() => ThreeMfParser.parse(Uint8List.fromList('not a zip'.codeUnits)),
          throwsA(isA<ModelParseException>()));
    });
  });
}
