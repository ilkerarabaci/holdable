import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/viewer/data/model_parser.dart';
import 'package:holdable/features/viewer/data/off_parser.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('OffParser', () {
    test('parses a triangle OFF (counts + bounds)', () {
      final m = OffParser.parse(_b('''OFF
3 1 0
0 0 0
2 0 0
0 3 0
3 0 1 2
'''));
      expect(m.vertexCount, 3);
      expect(m.triangleCount, 1);
      expect(m.bounds.maxX, 2);
      expect(m.bounds.maxY, 3);
    });

    test('fan-triangulates a quad face into 2 triangles', () {
      final m = OffParser.parse(_b('''OFF
4 1 0
0 0 0
1 0 0
1 1 0
0 1 0
4 0 1 2 3
'''));
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
    });

    test('skips # comments and blank lines, routes via ModelParser', () {
      final bytes = _b('''# a comment
OFF
# counts
3 1 0
0 0 0
1 0 0
0 1 0

3 0 1 2
''');
      expect(OffParser.parse(bytes).triangleCount, 1);
      expect(ModelParser.parse(bytes, format: 'off').triangleCount, 1);
    });

    test('empty / non-OFF input throws ModelParseException', () {
      expect(() => OffParser.parse(Uint8List(0)),
          throwsA(isA<ModelParseException>()));
      expect(() => OffParser.parse(_b('hello world')),
          throwsA(isA<ModelParseException>()));
    });
  });
}
