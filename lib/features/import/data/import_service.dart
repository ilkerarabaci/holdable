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

/// Picks a .obj/.stl from the device, copies it into the app documents
/// directory, and registers it with the library. Alpha = local-only.
class ImportService {
  ImportService(this.ref);
  final Ref ref;

  Future<ImportResult> pickAndImport() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
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
    final format = ModelFormat.fromExtension(picked.extension ?? '');
    if (format == null || picked.path == null) {
      return const ImportResult(ImportStatus.unsupported,
          message: 'Only .obj and .stl are supported in this version.');
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.${format.name}';
      await File(picked.path!).copy(dest);

      final model = LibraryModel(
        id: id,
        name: _baseName(picked.name),
        format: format,
        sizeBytes: picked.size,
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  static String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }
}

final importServiceProvider = Provider<ImportService>(ImportService.new);
