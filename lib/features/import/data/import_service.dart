import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';

/// Outcome of an import attempt, surfaced to the UI for feedback.
enum ImportStatus { added, cancelled, unsupported, error }

class ImportResult {
  const ImportResult(this.status, {this.model, this.message});
  final ImportStatus status;
  final LibraryModel? model;
  final String? message;
}

/// Imports models into the wallet. Two entry points share one copy-and-register
/// core: the file picker ([pickAndImport]) and incoming shares ([importPath]).
/// Alpha = local-only.
class ImportService {
  ImportService(this.ref);
  final Ref ref;

  /// Filters a set of incoming paths down to supported model files. Pure, so
  /// the share-intent handler can be reasoned about and tested without IO.
  static List<String> supportedPaths(Iterable<String> paths) => [
        for (final p in paths)
          if (ModelFormat.fromExtension(_ext(p)) != null) p,
      ];

  Future<ImportResult> pickAndImport() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['obj', 'stl'],
      );
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
    if (result == null || result.files.isEmpty) {
      return const ImportResult(ImportStatus.cancelled);
    }
    final picked = result.files.single;
    if (picked.path == null) {
      return const ImportResult(ImportStatus.unsupported);
    }
    return importPath(picked.path!, displayName: picked.name, size: picked.size);
  }

  /// Copies the file at [path] into app storage and registers it. Used by both
  /// the picker and the share-intent flow.
  Future<ImportResult> importPath(String path,
      {String? displayName, int? size}) async {
    final format = ModelFormat.fromExtension(_ext(path));
    if (format == null) {
      return const ImportResult(ImportStatus.unsupported,
          message: 'Only .obj and .stl are supported in this version.');
    }
    try {
      final source = File(path);
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.${format.name}';
      await source.copy(dest);

      final model = LibraryModel(
        id: id,
        name: _baseName(displayName ?? path.split(Platform.pathSeparator).last),
        format: format,
        sizeBytes: size ?? source.lengthSync(),
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot + 1) : '';
  }

  static String _baseName(String fileName) {
    final slash = fileName.lastIndexOf(RegExp(r'[\\/]'));
    final name = slash >= 0 ? fileName.substring(slash + 1) : fileName;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

final importServiceProvider = Provider<ImportService>(ImportService.new);
