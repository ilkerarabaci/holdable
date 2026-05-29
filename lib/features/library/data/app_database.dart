import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Persisted model metadata. The actual model files live in the app documents
/// directory; this table stores the wallet's index.
class Models extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get format => text()(); // ModelFormat.name ('obj' | 'stl')
  IntColumn get sizeBytes => integer()();
  TextColumn get filePath => text()();
  DateTimeColumn get importedAt => dateTime()();
  TextColumn get thumbnailPath => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Models])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'holdable'));

  @override
  int get schemaVersion => 1;

  Future<List<Model>> allModels() =>
      (select(models)..orderBy([(m) => OrderingTerm.desc(m.importedAt)])).get();

  Future<void> upsert(Insertable<Model> row) =>
      into(models).insertOnConflictUpdate(row);

  Future<void> deleteById(String id) =>
      (delete(models)..where((m) => m.id.equals(id))).go();

  Future<void> renameById(String id, String name) =>
      (update(models)..where((m) => m.id.equals(id)))
          .write(ModelsCompanion(name: Value(name)));

  Future<void> setThumbnailById(String id, String path) =>
      (update(models)..where((m) => m.id.equals(id)))
          .write(ModelsCompanion(thumbnailPath: Value(path)));
}
