import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';
import 'heightmap_converter.dart';

/// Outcome of an import attempt, surfaced to the UI for feedback.
enum ImportStatus { added, cancelled, unsupported, duplicate, error }

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

  Future<ImportResult> pickAndImport({
    Future<bool> Function(int sizeBytes)? confirmOversize,
  }) async {
    final FilePickerResult? result;
    try {
      // Use FileType.any, NOT FileType.custom with allowedExtensions: on
      // Android the Storage Access Framework greys out files whose extension
      // has no registered MIME type (.obj / .stl don't), so the user can't
      // select their own model — they could only get one in via the share
      // intent. FileType.any shows everything; we validate the extension
      // ourselves in [importPath] (returns ImportStatus.unsupported otherwise).
      result = await FilePicker.platform.pickFiles(type: FileType.any);
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
    // Soft cap: very large models load slowly and can push memory past budget
    // (see docs/perf-w3-baseline.md). Let the UI confirm before importing.
    if (picked.size > kMaxImportBytes && confirmOversize != null) {
      final proceed = await confirmOversize(picked.size);
      if (!proceed) return const ImportResult(ImportStatus.cancelled);
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
      final name =
          _baseName(displayName ?? path.split(Platform.pathSeparator).last);
      final resolvedSize = size ?? source.lengthSync();
      // Skip re-importing a model already in the wallet (same name+size+format).
      // Checked before copying so we don't leave an orphaned file.
      if (_isDuplicate(name, resolvedSize, format)) {
        return ImportResult(ImportStatus.duplicate,
            message: '"$name" is already in your library.');
      }
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.${format.name}';
      await source.copy(dest);

      final model = LibraryModel(
        id: id,
        name: name,
        format: format,
        sizeBytes: resolvedSize,
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  /// Imports a bundled CC0 sample model (from assets/sample_models/) into the
  /// wallet — used by the import sheet's "Sample models" option.
  Future<ImportResult> importAsset(String assetPath, String displayName) async {
    final format = ModelFormat.fromExtension(_ext(assetPath));
    if (format == null) return const ImportResult(ImportStatus.unsupported);
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      if (_isDuplicate(displayName, bytes.length, format)) {
        return ImportResult(ImportStatus.duplicate,
            message: '"$displayName" is already in your library.');
      }
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.${format.name}';
      await File(dest).writeAsBytes(bytes);

      final model = LibraryModel(
        id: id,
        name: displayName,
        format: format,
        sizeBytes: bytes.length,
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  /// True if a model with the same display name, byte size and format is already
  /// in the wallet — the practical signal for an exact re-import (each import
  /// gets a fresh id + copied file, so paths never match).
  bool _isDuplicate(String name, int sizeBytes, ModelFormat format) {
    final existing = ref.read(libraryControllerProvider);
    return existing.any((m) =>
        m.name == name && m.sizeBytes == sizeBytes && m.format == format);
  }

  /// Image extensions Skia can decode for the Image → 3D heightmap path.
  static const Set<String> _imageExts = {
    'png', 'jpg', 'jpeg', 'bmp', 'webp', 'gif',
  };

  static bool isSupportedImage(String path) =>
      _imageExts.contains(_ext(path).toLowerCase());

  /// Picks an image and turns it into a 3D heightmap relief (roadmap tier A).
  Future<ImportResult> pickImageAndImport() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.image);
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
    return importImageAs3D(picked.path!, displayName: picked.name);
  }

  /// Decodes the image at [path], builds a solid heightmap relief STL, and
  /// registers it as a normal model (so the viewer/thumbnail pipeline is reused).
  Future<ImportResult> importImageAs3D(String path,
      {String? displayName}) async {
    if (!isSupportedImage(path)) {
      return const ImportResult(ImportStatus.unsupported,
          message: 'Pick a PNG, JPG or BMP image.');
    }
    try {
      final bytes = await File(path).readAsBytes();
      // Decode on the UI isolate (Skia handles PNG/JPG/BMP/WebP/GIF).
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width;
      final h = image.height;
      image.dispose();
      if (bd == null) {
        return const ImportResult(ImportStatus.error,
            message: "Couldn't read that image.");
      }
      // Build the STL off the UI thread.
      final stl = await compute(
        _heightmapEntry,
        _HeightmapJob(bd.buffer.asUint8List(), w, h),
      );
      if (stl == null) {
        return const ImportResult(ImportStatus.error,
            message: "Couldn't build a 3D relief from that image.");
      }

      final name = _baseName(
          displayName ?? path.split(Platform.pathSeparator).last);
      // Same image + params → identical STL → same name+size → caught as a dup.
      if (_isDuplicate(name, stl.length, ModelFormat.stl)) {
        return ImportResult(ImportStatus.duplicate,
            message: '"$name" is already in your library.');
      }
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);
      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.stl';
      await File(dest).writeAsBytes(stl);

      final model = LibraryModel(
        id: id,
        name: name,
        format: ModelFormat.stl,
        sizeBytes: stl.length,
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

/// Soft cap for imports. Files larger than this prompt a confirmation before
/// loading — alpha scope is <=50 MB; 60 leaves headroom. A 50 MB STL already
/// sits near the 200 MB PSS budget (docs/perf-w3-baseline.md), so this guards
/// against accidentally importing something that loads slowly / runs hot.
const kMaxImportBytes = 60 * 1024 * 1024;

/// Payload for the off-isolate heightmap → STL conversion.
class _HeightmapJob {
  const _HeightmapJob(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

/// Isolate entry: raw RGBA image → binary STL bytes.
Uint8List? _heightmapEntry(_HeightmapJob job) =>
    heightmapToStl(rgba: job.rgba, imgW: job.width, imgH: job.height);

final importServiceProvider = Provider<ImportService>(ImportService.new);
