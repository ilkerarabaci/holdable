import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';
import 'conversion_service.dart';

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
          if (ModelFormat.fromExtension(_ext(p)) != null ||
              kConvertibleExtensions.contains(_ext(p).toLowerCase()))
            p,
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
      // Not natively parseable — but if it's a convertible format (.blend,
      // USD, …) route it through the conversion service, which returns a glb.
      final ext = _ext(path).toLowerCase();
      if (kConvertibleExtensions.contains(ext)) {
        return _importViaConversion(path, ext, displayName: displayName);
      }
      if (kUnsupportedCadExtensions.contains(ext)) {
        return ImportResult(ImportStatus.unsupported,
            message:
                "Holdable can't open .$ext directly. Export a STEP (.step) or "
                'IGES (.iges) file from your CAD tool and import that instead.');
      }
      return const ImportResult(ImportStatus.unsupported,
          message: 'Supported formats: .obj, .stl, .glb, .gltf, .ply, .3mf, .off, .dae, .3ds, .fbx (ASCII)');
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
      final dest = '${modelsDir.path}/$id.${format.fileExtension}';
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

  /// Sends a non-native file ([ext] in [kConvertibleExtensions]) to the
  /// conversion service, then imports the returned glb as a normal model — so
  /// the viewer/AR see a plain glb and nothing downstream needs to change.
  Future<ImportResult> _importViaConversion(String path, String ext,
      {String? displayName}) async {
    try {
      final source = File(path);
      final name =
          _baseName(displayName ?? path.split(Platform.pathSeparator).last);
      // Guard the upload before it leaves the device: cloud conversion is
      // capped (free tier) and the server hard-caps at 200 MB anyway, so fail
      // fast with a clear message rather than burning data on a doomed upload.
      final bytes = source.lengthSync();
      if (bytes > kMaxConvertUploadBytes) {
        final mb = (bytes / (1024 * 1024)).round();
        final cap = kMaxConvertUploadBytes ~/ (1024 * 1024);
        return ImportResult(ImportStatus.error,
            message: 'This file is ${mb}MB. Conversion is limited to ${cap}MB.');
      }
      final glb =
          await const ConversionService().convertToGlb(source.readAsBytesSync(), ext);

      if (_isDuplicate(name, glb.length, ModelFormat.glb)) {
        return ImportResult(ImportStatus.duplicate,
            message: '"$name" is already in your library.');
      }
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.glb';
      await File(dest).writeAsBytes(glb);

      final model = LibraryModel(
        id: id,
        name: name,
        format: ModelFormat.glb,
        sizeBytes: glb.length,
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } on ConversionException catch (e) {
      return ImportResult(ImportStatus.error, message: e.message);
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
      final dest = '${modelsDir.path}/$id.${format.fileExtension}';
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

/// Hard cap on what we'll upload for cloud conversion. Large files now go via
/// the GCS-upload path (which bypasses Cloud Run's 32 MiB request limit), so
/// this is the product cap, not a transport one. 200 MB = the paid-tier ceiling.
/// TODO(tier): drop to ~50 MB for free once entitlements ship.
const kMaxConvertUploadBytes = 200 * 1024 * 1024;

/// Proprietary / closed CAD formats we deliberately do NOT convert: there's no
/// open reader (FreeCAD/OpenCASCADE can't parse them — they'd need a licensed
/// commercial engine). When one is imported we point the user at the
/// interchange formats we DO support (STEP/IGES), which every CAD tool exports.
const Set<String> kUnsupportedCadExtensions = {
  'sldprt', 'sldasm', // SolidWorks
  'ipt', 'iam', // Inventor
  'catpart', 'catproduct', // CATIA
  'f3d', 'f3z', // Fusion 360
  'dwg', 'dxf', // AutoCAD (and mostly 2D)
  'x_t', 'x_b', // Parasolid
  'sat', // ACIS
};

final importServiceProvider = Provider<ImportService>(ImportService.new);
