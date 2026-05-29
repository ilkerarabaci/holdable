import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/library_model.dart';
import 'app_database.dart';

/// The app database. Overridden in tests with an in-memory executor; in the
/// app it opens the on-device SQLite file.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

LibraryModel _fromRow(Model r) => LibraryModel(
      id: r.id,
      name: r.name,
      format: ModelFormat.values.byName(r.format),
      sizeBytes: r.sizeBytes,
      filePath: r.filePath,
      importedAt: r.importedAt,
      thumbnailPath: r.thumbnailPath,
    );

ModelsCompanion _toCompanion(LibraryModel m) => ModelsCompanion.insert(
      id: m.id,
      name: m.name,
      format: m.format.name,
      sizeBytes: m.sizeBytes,
      filePath: m.filePath,
      importedAt: m.importedAt,
      thumbnailPath: Value(m.thumbnailPath),
    );

/// Holds the wallet's models. State is the synchronous source of truth for the
/// UI; Drift is the backing store, hydrated on build and written through on
/// every mutation. Swapping stores stays invisible to the presentation layer.
class LibraryController extends Notifier<List<LibraryModel>> {
  AppDatabase get _db => ref.read(databaseProvider);

  @override
  List<LibraryModel> build() {
    _hydrate();
    return const [];
  }

  Future<void> _hydrate() async {
    final rows = await _db.allModels();
    // Only adopt the stored list if no mutation landed while we were loading
    // (build() returns [] synchronously, so an import racing the hydrate must
    // not be clobbered). On a normal cold start state is still empty here.
    if (state.isEmpty) {
      state = rows.map(_fromRow).toList();
    }
  }

  Future<void> add(LibraryModel model) async {
    state = [model, ...state];
    await _db.upsert(_toCompanion(model));
  }

  Future<void> remove(String id) async {
    state = state.where((m) => m.id != id).toList();
    await _db.deleteById(id);
  }

  Future<void> rename(String id, String name) async {
    state = [
      for (final m in state) m.id == id ? m.copyWith(name: name) : m,
    ];
    await _db.renameById(id, name);
  }

  Future<void> setThumbnail(String id, String path) async {
    state = [
      for (final m in state)
        m.id == id ? m.copyWith(thumbnailPath: path) : m,
    ];
    await _db.setThumbnailById(id, path);
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, List<LibraryModel>>(
        LibraryController.new);
