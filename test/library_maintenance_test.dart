import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/library/data/library_controller.dart';
import 'package:holdable/features/library/domain/library_model.dart';
import 'package:holdable/features/viewer/data/thumbnail_service.dart';

LibraryModel _m(String id, String name, int size, ModelFormat fmt, int epochMs) =>
    LibraryModel(
      id: id,
      name: name,
      format: fmt,
      sizeBytes: size,
      filePath: '/models/$id.${fmt.name}',
      importedAt: DateTime.fromMillisecondsSinceEpoch(epochMs),
    );

void main() {
  group('duplicateIdsToRemove', () {
    test('keeps the earliest of an exact-duplicate group', () {
      final models = [
        _m('c', 'bitki', 5400, ModelFormat.obj, 3000), // newest dup
        _m('a', 'bitki', 5400, ModelFormat.obj, 1000), // earliest → keep
        _m('b', 'bitki', 5400, ModelFormat.obj, 2000), // dup
        _m('x', 'cube', 1500, ModelFormat.stl, 1500), // unique → keep
      ];
      final remove = duplicateIdsToRemove(models);
      expect(remove.toSet(), {'b', 'c'});
      expect(remove, isNot(contains('a')));
      expect(remove, isNot(contains('x')));
    });

    test('different size / format / name are not duplicates', () {
      final models = [
        _m('a', 'cube', 1500, ModelFormat.stl, 1000),
        _m('b', 'cube', 1501, ModelFormat.stl, 2000), // different size
        _m('c', 'cube', 1500, ModelFormat.obj, 3000), // different format
        _m('d', 'Cube', 1500, ModelFormat.stl, 4000), // different name (case)
      ];
      expect(duplicateIdsToRemove(models), isEmpty);
    });

    test('empty input', () {
      expect(duplicateIdsToRemove(const []), isEmpty);
    });
  });

  group('isThumbnailStale', () {
    test('null is stale', () {
      expect(isThumbnailStale(null), isTrue);
    });
    test('old unversioned path is stale', () {
      expect(isThumbnailStale('/thumbs/123.png'), isTrue);
    });
    test('current versioned path is fresh', () {
      expect(isThumbnailStale('/thumbs/123$kThumbnailVersionSuffix'), isFalse);
    });
  });
}
